// MobileGlues - gl/buffer.cpp
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header

#include "buffer.h"
#include "perf_counters.h"
#include "../egl/context.h"
#include <mutex>
#include <memory>
#include <ska/flat_hash_map.hpp>
#include <array>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include "texture.h"

#define DEBUG 0

// --- Emulated buffer-texture registry ---------------------------------------
//
// The emulated TBO is a snapshot: glTexBuffer copies the backing buffer's bytes
// into a plain 2D texture once, and nothing watched the buffer afterwards. Any
// glBufferData / glBufferSubData / glUnmapBuffer on the backing buffer then
// silently diverged from what the shader's texelFetch read -- MC 26.2's cloud
// faces and Sodium 0.9's section-time info both update their buffer textures
// that way, so the emulation served the byte image of the glTexBuffer moment
// forever. The registry maps an application buffer name to the 2D texture
// holding its snapshot so the buffer-mutation entry points below can re-upload.
//
// Known gap: coherent persistent mappings (glBufferStorage MAP_COHERENT) write
// without an unmap, and glCopyBufferSubData has no wrapper here to hook; both
// keep serving the stale snapshot until the next hooked mutation.
struct mg_tbo_backing_t {
    GLuint tex = 0;            // the snapshot texture (parked on unit 15)
    GLenum internalformat = 0; // the glTexBuffer internalformat
};
static ska::flat_hash_map<GLuint, mg_tbo_backing_t> g_tbo_backing;

GLuint bound_array;
static GLint maxBufferId = 0;
static GLint maxArrayId = 0;

// ---------------------------------------------------------------------------
// Per-share-group and per-context storage
//
// GL scopes buffer names to the share group -- two contexts created against each
// other see one set of names -- while vertex array objects and the current
// bindings are container state and belong to the context alone, even inside a
// share group. All of it used to be one process-wide set, so a second context
// inherited the first one's names, sizes and bindings.
//
// The tables stay private to this file and are selected by a thread_local
// pointer that eglMakeCurrent swaps, which is why the ~90 access sites only
// changed shape rather than routing through an accessor on every use.
// The state is held by pointer: the map moves its elements when it grows, and
// these thread_local pointers have to outlive other contexts being added.
// ---------------------------------------------------------------------------

namespace {

// CPU mirror of a buffer that has been bound as a uniform block (see the
// uniform-block proxy section further down).
struct ubo_shadow_t {
    std::vector<uint8_t> bytes;
    bool valid = false;      // bytes match the driver's copy
    bool proxyable = true;   // false once a read-back failed: pass binds through
    uint8_t* map_ptr = nullptr; // live write mapping, copied in at unmap
    size_t map_off = 0;
    size_t map_len = 0;
};

// One small driver buffer per uniform binding index, holding just the block
// the application bound there.
struct ubo_slot_t {
    GLuint proxy = 0;     // driver name
    size_t capacity = 0;  // GL size of the proxy
    GLuint src = 0;       // application buffer being stood in for; 0 = slot passes through
    size_t off = 0;
    size_t size = 0;
    std::vector<uint8_t> last; // what the proxy currently holds
};

struct buffer_group_state_t { // shared across a share group
    std::vector<GLuint> gen_buffers;
    std::vector<char> gen_buffer_exists;
    std::vector<GLuint> free_buffer_ids;
    std::vector<size_t> buffer_datasize;
    ska::flat_hash_map<GLuint, ubo_shadow_t> ubo_shadows;
};

struct buffer_ctx_state_t { // private to one context
    std::vector<GLuint> gen_arrays;
    std::vector<char> gen_array_exists;
    std::vector<GLuint> free_array_ids;
    std::vector<GLuint> element_array_buffer_per_vao;
    std::array<GLuint, 13> bound_buffers{};
    std::vector<ubo_slot_t> ubo_slots;
    // The driver's generic GL_UNIFORM_BUFFER binding was left on a proxy and
    // must be put back before anything addresses that target.
    bool ubo_generic_dirty = false;
    GLuint upload_stage = 0; // driver name of the staging buffer for unaligned uploads
};

std::mutex g_buf_mutex;
// The tables hold their state by pointer. A thread_local pointer into an entry is
// the whole point of the design -- the ~90 access sites read through g_bg/g_bc
// rather than looking anything up -- and the map moves its elements when it
// grows, so the entry itself must not be what moves. The unique_ptr stays put
// while the map rehashes around it.
ska::flat_hash_map<unsigned long long, std::unique_ptr<buffer_group_state_t>> g_buf_groups;
ska::flat_hash_map<unsigned long long, std::unique_ptr<buffer_ctx_state_t>> g_buf_ctxs;

buffer_group_state_t g_buf_group_default;
buffer_ctx_state_t g_buf_ctx_default;

thread_local buffer_group_state_t* g_bg = &g_buf_group_default;
thread_local buffer_ctx_state_t* g_bc = &g_buf_ctx_default;

} // namespace

void mg_buffer_bind_context(unsigned long long ctx_id, unsigned long long group_id) {
    if (ctx_id == 0) {
        g_bg = &g_buf_group_default;
        g_bc = &g_buf_ctx_default;
        return;
    }
    std::lock_guard<std::mutex> lock(g_buf_mutex);
    std::unique_ptr<buffer_group_state_t>& group = g_buf_groups[group_id];
    if (!group) group = std::make_unique<buffer_group_state_t>();
    std::unique_ptr<buffer_ctx_state_t>& ctx = g_buf_ctxs[ctx_id];
    if (!ctx) ctx = std::make_unique<buffer_ctx_state_t>();
    g_bg = group.get();
    g_bc = ctx.get();
}

void mg_buffer_forget_context(unsigned long long ctx_id) {
    if (ctx_id == 0) return;
    std::lock_guard<std::mutex> lock(g_buf_mutex);
    const auto it = g_buf_ctxs.find(ctx_id);
    if (it == g_buf_ctxs.end()) return;
    if (g_bc == it->second.get()) g_bc = &g_buf_ctx_default;
    g_buf_ctxs.erase(it);
}

#define g_gen_buffers (g_bg->gen_buffers)
#define g_gen_buffer_exists (g_bg->gen_buffer_exists)
#define g_free_buffer_ids (g_bg->free_buffer_ids)
#define g_buffer_datasize (g_bg->buffer_datasize)
#define g_gen_arrays (g_bc->gen_arrays)
#define g_gen_array_exists (g_bc->gen_array_exists)
#define g_free_array_ids (g_bc->free_array_ids)
#define g_element_array_buffer_per_vao (g_bc->element_array_buffer_per_vao)

enum BindingIndex : int {
    BI_ARRAY_BUFFER = 0,
    BI_ATOMIC_COUNTER,
    BI_COPY_READ,
    BI_COPY_WRITE,
    BI_DRAW_INDIRECT,
    BI_DISPATCH_INDIRECT,
    BI_ELEMENT_ARRAY,
    BI_PIXEL_PACK,
    BI_PIXEL_UNPACK,
    BI_SHADER_STORAGE,
    BI_TRANSFORM_FEEDBACK,
    BI_UNIFORM_BUFFER,
    BI_PARAMETER_BUFFER,
    BINDING_COUNT
};
#define g_bound_buffers_arr (g_bc->bound_buffers)
static_assert(BINDING_COUNT == 13, "buffer_ctx_state_t::bound_buffers must match BindingIndex");

static inline int ensure_buffer_capacity(GLuint id) {
    if ((int)g_gen_buffers.size() <= (int)id) {
        g_gen_buffers.resize(id + 1, 0);
        g_gen_buffer_exists.resize(id + 1, 0);
        if (g_buffer_datasize.size() <= (size_t)id) g_buffer_datasize.resize(id + 1, 0);
    }
    return 0;
}

static inline int ensure_array_capacity(GLuint id) {
    if ((int)g_gen_arrays.size() <= (int)id) {
        g_gen_arrays.resize(id + 1, 0);
        g_gen_array_exists.resize(id + 1, 0);
        if (g_element_array_buffer_per_vao.size() <= (size_t)id) g_element_array_buffer_per_vao.resize(id + 1, 0);
    }
    return 0;
}

GLuint gen_buffer() {
    if (!g_free_buffer_ids.empty()) {
        GLuint id = g_free_buffer_ids.back();
        g_free_buffer_ids.pop_back();
        ensure_buffer_capacity(id);
        g_gen_buffers[id] = 0;
        g_gen_buffer_exists[id] = 1;
        g_buffer_datasize[id] = 0;
        if (id > (GLuint)maxBufferId) maxBufferId = id;
        return id;
    }
    maxBufferId++;
    ensure_buffer_capacity((GLuint)maxBufferId);
    g_gen_buffers[maxBufferId] = 0;
    g_gen_buffer_exists[maxBufferId] = 1;
    g_buffer_datasize[maxBufferId] = 0;
    return (GLuint)maxBufferId;
}

GLboolean has_buffer(GLuint key) {
    return key < g_gen_buffer_exists.size() ? (g_gen_buffer_exists[key] != 0) : 0;
}

void modify_buffer(GLuint key, GLuint value) {
    if (key >= g_gen_buffers.size()) ensure_buffer_capacity(key);
    g_gen_buffers[key] = value;
    if (key >= g_gen_buffer_exists.size()) g_gen_buffer_exists.resize(key + 1, 0);
    g_gen_buffer_exists[key] = 1;
}

void remove_buffer(GLuint key) {
    if (key < g_gen_buffer_exists.size() && g_gen_buffer_exists[key]) {
        g_gen_buffer_exists[key] = 0;
        g_gen_buffers[key] = 0;
        if (key < g_buffer_datasize.size()) g_buffer_datasize[key] = 0;
        g_free_buffer_ids.push_back(key);
    }
}

GLuint find_real_buffer(GLuint key) {
    if (key < g_gen_buffers.size() && g_gen_buffer_exists[key]) return g_gen_buffers[key];
    return 0;
}

GLuint get_ibo_by_vao(GLuint vao) {
    if (vao < g_element_array_buffer_per_vao.size()) return g_element_array_buffer_per_vao[vao];
    return 0;
}

GLuint find_bound_array() {
    return bound_array;
}

void update_vao_ibo_binding(GLuint vao, GLuint ibo) {
    ensure_array_capacity(vao);
    g_element_array_buffer_per_vao[vao] = ibo;
}

void set_buffer_data_size(GLuint buffer, size_t size) {
    ensure_buffer_capacity(buffer);
    g_buffer_datasize[buffer] = size;
}

size_t get_buffer_data_size(GLuint buffer) {
    if (buffer < g_buffer_datasize.size()) return g_buffer_datasize[buffer];
    return 0;
}

static inline int binding_target_to_index(GLenum target) {
    switch (target) {
    case GL_ARRAY_BUFFER:
        return BI_ARRAY_BUFFER;
    case GL_ATOMIC_COUNTER_BUFFER:
        return BI_ATOMIC_COUNTER;
    case GL_COPY_READ_BUFFER:
        return BI_COPY_READ;
    case GL_COPY_WRITE_BUFFER:
        return BI_COPY_WRITE;
    case GL_DRAW_INDIRECT_BUFFER:
        return BI_DRAW_INDIRECT;
    case GL_DISPATCH_INDIRECT_BUFFER:
        return BI_DISPATCH_INDIRECT;
    case GL_ELEMENT_ARRAY_BUFFER:
        return BI_ELEMENT_ARRAY;
    case GL_PIXEL_PACK_BUFFER:
        return BI_PIXEL_PACK;
    case GL_PIXEL_UNPACK_BUFFER:
        return BI_PIXEL_UNPACK;
    case GL_SHADER_STORAGE_BUFFER:
        return BI_SHADER_STORAGE;
    case GL_TRANSFORM_FEEDBACK_BUFFER:
        return BI_TRANSFORM_FEEDBACK;
    case GL_UNIFORM_BUFFER:
        return BI_UNIFORM_BUFFER;
    case GL_PARAMETER_BUFFER:
        return BI_PARAMETER_BUFFER;
    default:
        return -1;
    }
}

void set_bound_buffer_by_target(GLenum target, GLuint buffer) {
    int idx = binding_target_to_index(target);
    if (idx >= 0) g_bound_buffers_arr[idx] = buffer;
}

// find_bound_buffer below answers the *_BINDING query enums, which is what
// glGetIntegerv passes it. Callers holding a bind target need this one instead:
// handing a target to find_bound_buffer falls through to its default and comes
// back 0, which is a valid buffer name and so goes unnoticed.
GLuint find_bound_buffer_by_target(GLenum target) {
    if (target == GL_ELEMENT_ARRAY_BUFFER) return get_ibo_by_vao(find_bound_array());
    const int idx = binding_target_to_index(target);
    return idx >= 0 ? g_bound_buffers_arr[idx] : 0;
}

// The name the *driver* has bound to `target`, i.e. what
// GLES.glGetIntegerv(<target>_BINDING) would answer, worked out from the tracked
// bindings rather than by asking the driver.
//
// Buffer names are renamed across this boundary: the application sees names
// gen_buffer() hands out and the driver sees the ones glGenBuffers gave back, so
// find_bound_buffer_by_target's answer must not be passed to GLES.glBindBuffer
// unmapped. This one may. A name the application bound without ever generating it
// is forwarded verbatim by glBindBuffer -- GLES creates the object on first bind
// -- so it is its own driver name.
//
// Two limits, both shared with this layer's own glGetIntegerv:
//   - It reports the last name bound to the target, and glDeleteBuffers does not
//     clear the binding slots (only GL_PARAMETER_BUFFER, which has no driver-side
//     binding to fall back on). Deleting a still-bound buffer resets the driver's
//     binding to 0 while this keeps reporting the dead name.
//   - It is the tracked state, so it is only the driver's state where the two
//     agree. Every internal path that binds GL_ELEMENT_ARRAY_BUFFER or
//     GL_DRAW_INDIRECT_BUFFER through GLES.* directly (gl/multidraw.cpp,
//     gl/drawing.cpp, gl/restart.cpp) saves and restores around its own work, so
//     they disagree only inside those windows -- ask before the temporary bind,
//     never during it. gl/gl.cpp's depth-clear triangle is the one path that does
//     not: it leaves the driver on vertex array 0 and GL_ARRAY_BUFFER 0 without
//     putting the application's back, which desynchronises the element array
//     binding too, since that is vertex array state.
//
// GL_PARAMETER_BUFFER has no GLES binding at all; the mapped name is returned for
// it anyway, because gl/multidraw.cpp is the only thing that asks and it needs the
// real object to bind somewhere else.
GLuint mg_driver_bound_buffer(GLenum target) {
    const GLuint name = find_bound_buffer_by_target(target);
    const GLuint real = (name == 0 || !has_buffer(name)) ? name : find_real_buffer(name);
#if GLOBAL_DEBUG
    // The divergence this answer is vulnerable to -- driver state mutated
    // behind the frontend's back -- is undetectable at runtime: the tracked
    // state always has an answer and cannot know it is stale. So debug builds
    // pay the round-trip this function exists to avoid, and scream on a
    // mismatch instead of letting a wrong binding surface three calls later as
    // a skipped draw or a corrupted restore. Release builds trust the tracking.
    if (GLES.glGetIntegerv) {
        GLenum pname = 0;
        switch (target) {
        case GL_ARRAY_BUFFER:          pname = GL_ARRAY_BUFFER_BINDING; break;
        case GL_ELEMENT_ARRAY_BUFFER:  pname = GL_ELEMENT_ARRAY_BUFFER_BINDING; break;
        case GL_DRAW_INDIRECT_BUFFER:  pname = GL_DRAW_INDIRECT_BUFFER_BINDING; break;
        case GL_PIXEL_UNPACK_BUFFER:   pname = GL_PIXEL_UNPACK_BUFFER_BINDING; break;
        case GL_PIXEL_PACK_BUFFER:     pname = GL_PIXEL_PACK_BUFFER_BINDING; break;
        case GL_COPY_READ_BUFFER:      pname = GL_COPY_READ_BUFFER_BINDING; break;
        case GL_COPY_WRITE_BUFFER:     pname = GL_COPY_WRITE_BUFFER_BINDING; break;
        default: break;
        }
        if (pname != 0) {
            GLint driver = 0;
            GLES.glGetIntegerv(pname, &driver);
            if (static_cast<GLuint>(driver) != real) {
                LOG_E("mg_driver_bound_buffer(0x%X): tracked %u (real %u) but the driver holds %u -- "
                      "something mutated this binding without going through the frontend",
                      target, name, real, static_cast<GLuint>(driver))
            }
        }
    }
#endif
    return real;
}

GLuint find_bound_buffer(GLenum key) {
    GLenum target = 0;
    switch (key) {
    case GL_ARRAY_BUFFER_BINDING:
        target = GL_ARRAY_BUFFER;
        break;
    case GL_ATOMIC_COUNTER_BUFFER_BINDING:
        target = GL_ATOMIC_COUNTER_BUFFER;
        break;
    case GL_COPY_READ_BUFFER_BINDING:
        target = GL_COPY_READ_BUFFER;
        break;
    case GL_COPY_WRITE_BUFFER_BINDING:
        target = GL_COPY_WRITE_BUFFER;
        break;
    case GL_DRAW_INDIRECT_BUFFER_BINDING:
        target = GL_DRAW_INDIRECT_BUFFER;
        break;
    case GL_DISPATCH_INDIRECT_BUFFER_BINDING:
        target = GL_DISPATCH_INDIRECT_BUFFER;
        break;
    case GL_ELEMENT_ARRAY_BUFFER_BINDING:
        target = GL_ELEMENT_ARRAY_BUFFER;
        break;
    case GL_PIXEL_PACK_BUFFER_BINDING:
        target = GL_PIXEL_PACK_BUFFER;
        break;
    case GL_PIXEL_UNPACK_BUFFER_BINDING:
        target = GL_PIXEL_UNPACK_BUFFER;
        break;
    case GL_SHADER_STORAGE_BUFFER_BINDING:
        target = GL_SHADER_STORAGE_BUFFER;
        break;
    case GL_TRANSFORM_FEEDBACK_BUFFER_BINDING:
        target = GL_TRANSFORM_FEEDBACK_BUFFER;
        break;
    case GL_UNIFORM_BUFFER_BINDING:
        target = GL_UNIFORM_BUFFER;
        break;
    case GL_PARAMETER_BUFFER_BINDING:
        target = GL_PARAMETER_BUFFER;
        break;
    default:
        target = 0;
        break;
    }
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        return get_ibo_by_vao(find_bound_array());
    }
    int idx = binding_target_to_index(target);
    if (idx >= 0) return g_bound_buffers_arr[idx];
    return 0;
}

GLuint gen_array() {
    if (!g_free_array_ids.empty()) {
        GLuint id = g_free_array_ids.back();
        g_free_array_ids.pop_back();
        ensure_array_capacity(id);
        g_gen_arrays[id] = 0;
        g_gen_array_exists[id] = 1;
        g_element_array_buffer_per_vao[id] = 0;
        if (id > (GLuint)maxArrayId) maxArrayId = id;
        return id;
    }
    maxArrayId++;
    ensure_array_capacity((GLuint)maxArrayId);
    g_gen_arrays[maxArrayId] = 0;
    g_gen_array_exists[maxArrayId] = 1;
    g_element_array_buffer_per_vao[maxArrayId] = 0;
    return (GLuint)maxArrayId;
}

GLboolean has_array(GLuint key) {
    return key < g_gen_array_exists.size() ? (g_gen_array_exists[key] != 0) : 0;
}

void modify_array(GLuint key, GLuint value) {
    if (key >= g_gen_arrays.size()) ensure_array_capacity(key);
    g_gen_arrays[key] = value;
    if (key >= g_gen_array_exists.size()) g_gen_array_exists.resize(key + 1, 0);
    g_gen_array_exists[key] = 1;
}

void remove_array(GLuint key) {
    if (key < g_gen_array_exists.size() && g_gen_array_exists[key]) {
        g_gen_array_exists[key] = 0;
        g_gen_arrays[key] = 0;
        if (key < g_element_array_buffer_per_vao.size()) g_element_array_buffer_per_vao[key] = 0;
        g_free_array_ids.push_back(key);
    }
}

GLuint find_real_array(GLuint key) {
    if (key < g_gen_arrays.size() && g_gen_array_exists[key]) return g_gen_arrays[key];
    return 0;
}

static GLenum get_binding_query(GLenum target) {
    switch (target) {
    case GL_ARRAY_BUFFER:
        return GL_ARRAY_BUFFER_BINDING;
    case GL_ELEMENT_ARRAY_BUFFER:
        return GL_ELEMENT_ARRAY_BUFFER_BINDING;
    case GL_PIXEL_PACK_BUFFER:
        return GL_PIXEL_PACK_BUFFER_BINDING;
    case GL_PIXEL_UNPACK_BUFFER:
        return GL_PIXEL_UNPACK_BUFFER_BINDING;
    case GL_COPY_WRITE_BUFFER:
        return GL_COPY_WRITE_BUFFER_BINDING;
    case GL_COPY_READ_BUFFER:
        return GL_COPY_READ_BUFFER_BINDING;
    case GL_UNIFORM_BUFFER:
        return GL_UNIFORM_BUFFER_BINDING;
    case GL_SHADER_STORAGE_BUFFER:
        return GL_SHADER_STORAGE_BUFFER_BINDING;
    case GL_TRANSFORM_FEEDBACK_BUFFER:
        return GL_TRANSFORM_FEEDBACK_BUFFER_BINDING;
    case GL_ATOMIC_COUNTER_BUFFER:
        return GL_ATOMIC_COUNTER_BUFFER_BINDING;
    case GL_DRAW_INDIRECT_BUFFER:
        return GL_DRAW_INDIRECT_BUFFER_BINDING;
    case GL_DISPATCH_INDIRECT_BUFFER:
        return GL_DISPATCH_INDIRECT_BUFFER_BINDING;
    default:
        return 0;
    }
}

void InitBufferMap(size_t expectedSize) {
    g_gen_buffers.reserve(expectedSize + 2);
    g_gen_buffer_exists.reserve(expectedSize + 2);
    g_buffer_datasize.reserve(expectedSize + 2);
    g_gen_buffers.resize(1, 0);
    g_gen_buffer_exists.resize(1, 0);
    g_buffer_datasize.resize(1, 0);
}

void InitVertexArrayMap(size_t expectedSize) {
    g_gen_arrays.reserve(expectedSize + 2);
    g_gen_array_exists.reserve(expectedSize + 2);
    g_element_array_buffer_per_vao.reserve(expectedSize + 2);
    g_gen_arrays.resize(1, 0);
    g_gen_array_exists.resize(1, 0);
    g_element_array_buffer_per_vao.resize(1, 0);
}

// --- Uniform-block proxies (Air) --------------------------------------------
//
// Minecraft 26 keeps its uniform blocks in large ring buffers and binds one
// block at a time with glBindBufferRange. ANGLE's Metal backend converts
// std140 blocks to Metal layout (ProgramExecutableMtl::
// legalizeUniformBufferOffsets), and for a range binding it converts
// everything from the bound offset to the END of the buffer -- once per
// distinct offset, again after every write to the buffer, each time into a
// freshly allocated Metal buffer of that size, after a CPU read of the live
// buffer. With hundreds of binds a frame into multi-megabyte ring buffers that
// was 60-90% of the render thread on 26.x, measured by Air's sampler, where
// 1.21 (no uniform buffers) holds 120 fps.
//
// It also made every write map of such a buffer wait for the GPU: blocks that
// need no conversion were bound straight from the ring buffer, so the next
// glMapBufferRange into it (ANGLE syncs any non-UNSYNCHRONIZED write map of a
// buffer the GPU is using) blocked until the GPU caught up.
//
// A uniform binding is redirected here to a small per-index proxy holding just
// that block, bound at offset 0, so ANGLE converts one block and the source
// buffer never reaches the GPU. The bytes come from a CPU mirror of the source buffer that every
// write path in this file keeps current (glBufferData, glBufferSubData,
// map/unmap, glCopyBufferSubData); a mirror starts with one read-back of the
// driver's copy. A write that overlaps a block standing in a proxy refreshes
// that proxy at once, so a draw always sees what GL says it should.
// MG_UBO_PROXY=0 turns the whole thing off.

namespace {
constexpr size_t kUboProxyMaxBlock = 64 * 1024;         // no uniform block is larger
constexpr size_t kUboShadowMaxBuffer = 64 * 1024 * 1024; // don't mirror anything bigger

bool ubo_proxy_enabled() {
    static const bool on = [] {
        const char* e = getenv("MG_UBO_PROXY");
        const bool enabled = !(e && e[0] == '0');
        LOG_W_FORCE("[MG] uniform-block proxy %s", enabled ? "on" : "off (MG_UBO_PROXY=0)")
        return enabled;
    }();
    return on;
}

inline void ubo_restore_generic() {
    if (!g_bc->ubo_generic_dirty) return;
    g_bc->ubo_generic_dirty = false;
    GLES.glBindBuffer(GL_UNIFORM_BUFFER, mg_driver_bound_buffer(GL_UNIFORM_BUFFER));
}

inline void ubo_restore_generic_for(GLenum target) {
    if (target == GL_UNIFORM_BUFFER) ubo_restore_generic();
}

ubo_shadow_t* ubo_shadow_of(GLuint buffer) {
    if (buffer == 0) return nullptr;
    auto& shadows = g_bg->ubo_shadows;
    if (shadows.empty()) return nullptr;
    const auto it = shadows.find(buffer);
    return it == shadows.end() ? nullptr : &it->second;
}

// Seed a mirror from the driver: one read mapping, which waits for the GPU at
// most once per buffer.
bool ubo_shadow_fill(GLuint buffer, ubo_shadow_t& s) {
    const size_t size = get_buffer_data_size(buffer);
    const GLuint real = find_real_buffer(buffer);
    if (size == 0 || size > kUboShadowMaxBuffer || real == 0 || s.map_ptr) return false;
    GLES.glBindBuffer(GL_COPY_READ_BUFFER, real);
    const void* p = GLES.glMapBufferRange(GL_COPY_READ_BUFFER, 0, static_cast<GLsizeiptr>(size), GL_MAP_READ_BIT);
    if (p) {
        const auto* bytes = static_cast<const uint8_t*>(p);
        s.bytes.assign(bytes, bytes + size);
        GLES.glUnmapBuffer(GL_COPY_READ_BUFFER);
    } else {
        GLES.glGetError(); // the failed map's own error, not the application's
    }
    GLES.glBindBuffer(GL_COPY_READ_BUFFER, mg_driver_bound_buffer(GL_COPY_READ_BUFFER));
    s.valid = p != nullptr;
    mg_perf_ubo_readbacks.fetch_add(1, std::memory_order_relaxed);
    return s.valid;
}

ubo_slot_t& ubo_slot(GLuint index) {
    auto& slots = g_bc->ubo_slots;
    if (index >= slots.size()) slots.resize(index + 1);
    return slots[index];
}

// Put a block in the slot's proxy and bind the proxy at `index`. Unchanged
// bytes skip both: the proxy is already bound there with this size.
void ubo_slot_load(GLuint index, ubo_slot_t& slot, const uint8_t* src, size_t size) {
    mg_perf_ubo_proxied.fetch_add(1, std::memory_order_relaxed);
    if (slot.last.size() == size && memcmp(slot.last.data(), src, size) == 0) return;
    mg_perf_ubo_uploads.fetch_add(1, std::memory_order_relaxed);

    // Room past the std140 size so a block whose Metal layout is larger still
    // fits without ANGLE falling back to conversion for lack of space.
    const size_t need = ((size + 255) & ~static_cast<size_t>(255)) + 256;
    if (!slot.proxy) GLES.glGenBuffers(1, &slot.proxy);
    // Always rewrite the whole proxy. A partial write to a buffer the GPU still
    // reads makes ANGLE blit the untouched rest into a new buffer, and a
    // GPU-written buffer then costs a GPU wait to read on the CPU.
    const size_t upload = slot.capacity < need ? need : slot.capacity;
    static thread_local std::vector<uint8_t> staging;
    if (staging.size() < upload) staging.resize(upload);
    memcpy(staging.data(), src, size);
    memset(staging.data() + size, 0, upload - size);
    GLES.glBindBuffer(GL_UNIFORM_BUFFER, slot.proxy);
    if (slot.capacity < need) {
        GLES.glBufferData(GL_UNIFORM_BUFFER, static_cast<GLsizeiptr>(upload), staging.data(), GL_DYNAMIC_DRAW);
        slot.capacity = upload;
    } else {
        GLES.glBufferSubData(GL_UNIFORM_BUFFER, 0, static_cast<GLsizeiptr>(upload), staging.data());
    }
    // Rebinding marks ANGLE's uniform bindings dirty, which is what makes it
    // convert the new contents for the next draw.
    GLES.glBindBufferRange(GL_UNIFORM_BUFFER, index, slot.proxy, 0, static_cast<GLsizeiptr>(size));
    g_bc->ubo_generic_dirty = true;
    slot.last.assign(src, src + size);
}

void ubo_slot_clear(ubo_slot_t& slot) {
    slot.src = 0;
    slot.last.clear();
}

// Redirect a uniform range binding to a proxy if that's worthwhile. Returns
// false to let the caller bind the real buffer.
bool ubo_try_proxy(GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    if (!ubo_proxy_enabled()) return false;
    if (buffer == 0 || !has_buffer(buffer) || offset < 0 || size <= 0) return false;
    const size_t total = get_buffer_data_size(buffer);
    const size_t off = static_cast<size_t>(offset);
    const size_t sz = static_cast<size_t>(size);
    if (total == 0 || total > kUboShadowMaxBuffer || off + sz > total) return false;
    // Every uniform bind is proxied, small buffers and the tail of a ring
    // included: a source buffer the GPU never reads directly is also one the
    // application can map for writing without ANGLE first waiting for the GPU
    // (a write map without GL_MAP_UNSYNCHRONIZED_BIT syncs on any GPU use).
    if (sz > kUboProxyMaxBlock) return false;

    ubo_shadow_t& s = g_bg->ubo_shadows[buffer];
    if (!s.proxyable || s.map_ptr) return false;
    if (!s.valid || s.bytes.size() != total) {
        if (!ubo_shadow_fill(buffer, s)) {
            s.proxyable = false;
            LOG_W_FORCE("[MG] uniform-block proxy: couldn't read buffer %u back, binding it directly", buffer)
            return false;
        }
    }
    ubo_slot_t& slot = ubo_slot(index);
    slot.src = buffer;
    slot.off = off;
    slot.size = sz;
    ubo_slot_load(index, slot, s.bytes.data() + off, sz);
    // The driver's generic binding may be anything now; GL says it is `buffer`.
    g_bc->ubo_generic_dirty = true;
    return true;
}

// After [begin, end) of `buffer` changed, bring every proxy standing in for
// part of that range up to date. A proxy whose mirror can't be trusted any
// more goes back to binding the real buffer.
void ubo_refresh_slots(GLuint buffer, size_t begin, size_t end) {
    auto& slots = g_bc->ubo_slots;
    for (GLuint i = 0; i < slots.size(); ++i) {
        ubo_slot_t& slot = slots[i];
        if (slot.src != buffer) continue;
        if (begin >= slot.off + slot.size || end <= slot.off) continue;
        ubo_shadow_t* s = ubo_shadow_of(buffer);
        bool ok = s != nullptr && s->proxyable && !s->map_ptr;
        if (ok && (!s->valid || s->bytes.size() != get_buffer_data_size(buffer))) ok = ubo_shadow_fill(buffer, *s);
        if (ok && slot.off + slot.size <= s->bytes.size()) {
            ubo_slot_load(i, slot, s->bytes.data() + slot.off, slot.size);
            continue;
        }
        GLES.glBindBufferRange(GL_UNIFORM_BUFFER, i, find_real_buffer(buffer), static_cast<GLintptr>(slot.off),
                               static_cast<GLsizeiptr>(slot.size));
        g_bc->ubo_generic_dirty = true;
        ubo_slot_clear(slot);
    }
}

// Write paths. Each is a no-op for buffers that were never proxied.
void ubo_mirror_write(GLuint buffer, size_t off, const void* data, size_t len) {
    ubo_shadow_t* s = ubo_shadow_of(buffer);
    if (!s || !data || len == 0) return;
    if (s->valid && off + len <= s->bytes.size()) {
        memcpy(s->bytes.data() + off, data, len);
    } else {
        s->valid = false;
    }
    ubo_refresh_slots(buffer, off, off + len);
}

void ubo_mirror_respecify(GLuint buffer, size_t size, const void* data) {
    ubo_shadow_t* s = ubo_shadow_of(buffer);
    if (!s) return;
    s->map_ptr = nullptr;
    if (size <= kUboShadowMaxBuffer) {
        if (data) {
            const auto* bytes = static_cast<const uint8_t*>(data);
            s->bytes.assign(bytes, bytes + size);
        } else {
            s->bytes.assign(size, 0); // undefined contents; zeros are as good as any
        }
        s->valid = true;
    } else {
        s->bytes.clear();
        s->bytes.shrink_to_fit();
        s->valid = false;
    }
    ubo_refresh_slots(buffer, 0, SIZE_MAX);
}

void ubo_note_map(GLuint buffer, size_t off, size_t len, GLbitfield access, void* ptr) {
    if (!ptr || (access & GL_MAP_WRITE_BIT) == 0) return;
    ubo_shadow_t* s = ubo_shadow_of(buffer);
    if (!s) return;
    s->map_ptr = static_cast<uint8_t*>(ptr);
    s->map_off = off;
    s->map_len = len;
}

// Copy a write mapping into the mirror; must run before the driver unmaps.
// Returns whether proxies need refreshing once it has.
bool ubo_take_unmap(GLuint buffer, size_t* begin, size_t* end) {
    ubo_shadow_t* s = ubo_shadow_of(buffer);
    if (!s || !s->map_ptr) return false;
    if (s->valid && s->map_off + s->map_len <= s->bytes.size()) {
        memcpy(s->bytes.data() + s->map_off, s->map_ptr, s->map_len);
    } else {
        s->valid = false;
    }
    *begin = s->map_off;
    *end = s->map_off + s->map_len;
    s->map_ptr = nullptr;
    return true;
}

void ubo_forget_buffer(GLuint buffer) {
    g_bg->ubo_shadows.erase(buffer);
    auto& slots = g_bc->ubo_slots;
    for (GLuint i = 0; i < slots.size(); ++i) {
        if (slots[i].src != buffer) continue;
        // GL unbinds a deleted buffer from the current context's bindings.
        GLES.glBindBufferBase(GL_UNIFORM_BUFFER, i, 0);
        g_bc->ubo_generic_dirty = true;
        ubo_slot_clear(slots[i]);
    }
}
} // namespace

extern "C" __attribute__((visibility("default"))) void mg_perf_ubo_snapshot(uint64_t* proxied, uint64_t* uploads,
                                                                            uint64_t* passthrough,
                                                                            uint64_t* readbacks) {
    *proxied = mg_perf_ubo_proxied.exchange(0, std::memory_order_relaxed);
    *uploads = mg_perf_ubo_uploads.exchange(0, std::memory_order_relaxed);
    *passthrough = mg_perf_ubo_passthrough.exchange(0, std::memory_order_relaxed);
    *readbacks = mg_perf_ubo_readbacks.exchange(0, std::memory_order_relaxed);
}

void glGenBuffers(GLsizei n, GLuint* buffers) {
    LOG()
    LOG_D("glGenBuffers(%i, %p)", n, buffers)
    for (int i = 0; i < n; ++i) {
        buffers[i] = gen_buffer();
    }
}

void glDeleteBuffers(GLsizei n, const GLuint* buffers) {
    LOG()
    LOG_D("glDeleteBuffers(%i, %p)", n, buffers)
    for (int i = 0; i < n; ++i) {
        // GL resets a binding to 0 when the bound buffer is deleted. The
        // parameter buffer slot is the only source of truth gl/multidraw.cpp has
        // for where the draw count lives -- there is no driver-side binding to
        // cross-check it against -- and deleted ids are recycled by gen_buffer(),
        // so a stale slot would silently point at somebody else's buffer.
        if (buffers[i] != 0 && find_bound_buffer(GL_PARAMETER_BUFFER_BINDING) == buffers[i]) {
            set_bound_buffer_by_target(GL_PARAMETER_BUFFER, 0);
        }
        // A deleted buffer must stop refreshing whatever snapshot it backed:
        // recycled names would otherwise push fresh garbage into a live
        // buffer texture.
        g_tbo_backing.erase(buffers[i]);
        if (buffers[i] != 0) ubo_forget_buffer(buffers[i]);
        if (find_real_buffer(buffers[i])) {
            GLuint real_buff = find_real_buffer(buffers[i]);
            GLES.glDeleteBuffers(1, &real_buff);
            CHECK_GL_ERROR
        }
        remove_buffer(buffers[i]);
    }
}

GLboolean glIsBuffer(GLuint buffer) {
    LOG()
    LOG_D("glIsBuffer, buffer = %d", buffer)
    return has_buffer(buffer);
}

void glBindBuffer(GLenum target, GLuint buffer) {
    LOG()
    LOG_D("glBindBuffer, target = %s, buffer = %d", glEnumToString(target), buffer)
    set_bound_buffer_by_target(target, buffer);
    // Every path below binds the driver's generic uniform binding itself.
    if (target == GL_UNIFORM_BUFFER) g_bc->ubo_generic_dirty = false;

    if (target == GL_PARAMETER_BUFFER) {
        // GLES has no GL_PARAMETER_BUFFER. The binding is tracked here and read
        // back by gl/multidraw.cpp for glMultiDraw*IndirectCount; forwarding the
        // target to the driver would only raise GL_INVALID_ENUM. The backing
        // object still has to exist, because nothing else will create it.
        if (buffer != 0 && has_buffer(buffer) && !find_real_buffer(buffer)) {
            GLuint real_buffer = 0;
            GLES.glGenBuffers(1, &real_buffer);
            modify_buffer(buffer, real_buffer);
            CHECK_GL_ERROR
        }
        return;
    }

    // GLES 3.0/3.1 has no GL_TEXTURE_BUFFER binding point either. While the
    // buffer-texture emulation is active the binding stays tracked (the
    // set_bound_buffer_by_target above already sees every target) and the
    // backing object is created here, but the target itself never reaches the
    // driver: forwarding it only raised GL_INVALID_ENUM, and the driver-side
    // binding never mattered -- the emulation reads the store through the
    // pixel-unpack path. Mutations through this target borrow
    // GL_COPY_WRITE_BUFFER (see borrowed_target_t) and refresh the snapshot.
    if (target == GL_TEXTURE_BUFFER && hardware->emulate_texture_buffer) {
        if (buffer != 0 && has_buffer(buffer) && !find_real_buffer(buffer)) {
            GLuint real_buffer = 0;
            GLES.glGenBuffers(1, &real_buffer);
            modify_buffer(buffer, real_buffer);
            CHECK_GL_ERROR
        }
        return;
    }

    // save ibo binding to vao
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        update_vao_ibo_binding(find_bound_array(), buffer);
    }

    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glBindBuffer(target, buffer);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }
    LOG_D("glBindBuffer: %d -> %d", buffer, real_buffer)
    GLES.glBindBuffer(target, real_buffer);
    CHECK_GL_ERROR
}

static std::vector<GLuint> g_buffer_map_ssbo_id;

void glBindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    LOG()
    LOG_D("glBindBufferRange, target = %s, index = %d, buffer = %d, offset = %p, size = %zi", glEnumToString(target),
          index, buffer, (void*)offset, size)

    if (target == GL_UNIFORM_BUFFER) {
        // An indexed bind also sets the generic binding.
        set_bound_buffer_by_target(GL_UNIFORM_BUFFER, buffer);
        if (ubo_try_proxy(index, buffer, offset, size)) return;
        ubo_slot_clear(ubo_slot(index));
        g_bc->ubo_generic_dirty = false; // the bind below puts the driver's generic binding right
        mg_perf_ubo_passthrough.fetch_add(1, std::memory_order_relaxed);
    }

    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glBindBufferRange(target, index, buffer, offset, size);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }
    GLES.glBindBufferRange(target, index, real_buffer, offset, size);
    CHECK_GL_ERROR
}

void glBindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    LOG()
    LOG_D("glBindBufferBase, target = %s, index = %d, buffer = %d", glEnumToString(target), index, buffer)

    if (target == GL_UNIFORM_BUFFER) {
        set_bound_buffer_by_target(GL_UNIFORM_BUFFER, buffer);
        const size_t total = buffer != 0 ? get_buffer_data_size(buffer) : 0;
        if (total > 0 && ubo_try_proxy(index, buffer, 0, static_cast<GLsizeiptr>(total))) return;
        ubo_slot_clear(ubo_slot(index));
        g_bc->ubo_generic_dirty = false;
        mg_perf_ubo_passthrough.fetch_add(1, std::memory_order_relaxed);
    }

    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glBindBufferBase(target, index, buffer);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }
    GLES.glBindBufferBase(target, index, real_buffer);
    if (target == GL_SHADER_STORAGE_BUFFER) {
        if (g_buffer_map_ssbo_id.empty()) {
            g_buffer_map_ssbo_id.resize(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, 0);
        }
        g_buffer_map_ssbo_id[index] = buffer;
    }
    CHECK_GL_ERROR
}

void glBindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    LOG()
    LOG_D("glBindVertexBuffer, bindingindex = %d, buffer = %d, offset = %p, stride = %i", bindingindex, buffer, offset,
          stride)
    // Todo: should record fake buffer binding here, when glGetVertexArrayIntegeri_v is called, should return fake
    // buffer id
    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glBindVertexBuffer(bindingindex, buffer, offset, stride);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }
    GLES.glBindVertexBuffer(bindingindex, real_buffer, offset, stride);
    CHECK_GL_ERROR
}

// The transfer pair GLES accepts for a given sized internalformat.
//
// The texture-buffer emulation used to allocate and upload with a hardcoded
// GL_RED_INTEGER + GL_BYTE whatever the internalformat was. ES validates
// internalformat/format/type as a triple, and that one is legal for exactly one
// format -- GL_R8I. Everything else (GL_R32I, GL_RGBA32F, even GL_R8UI, which
// wants GL_UNSIGNED_BYTE) failed the glTexImage2D with GL_INVALID_OPERATION,
// left level 0 undefined, and the emulated texelFetch read zeros from an
// incomplete texture. Sized here from the same table as the texel size, so the
// two cannot drift apart.
//
// Returns false for a format with no ES-legal pair -- the normalised 16-bit ones
// need EXT_texture_norm16, and depth formats are not texture-buffer formats at
// all. The caller drops the call instead of guessing.
//
// Deliberately wider than GL 4.6 table 8.16, which lists only the 32-bit
// three-component forms among the RGB ones: the extra entries here (GL_RGB8,
// GL_RGB8I/UI, GL_RGB16I/UI/F) are all valid ES triples, so emulating them costs
// nothing, while refusing them would only break an application that already works
// against the permissive desktop drivers. Being stricter than the hardware buys
// no correctness.
bool get_internal_format_transfer(GLenum internalformat, GLenum* format, GLenum* type) {
    switch (internalformat) {
    // clang-format off
    case GL_R8:        *format = GL_RED;           *type = GL_UNSIGNED_BYTE;  return true;
    case GL_R8I:       *format = GL_RED_INTEGER;   *type = GL_BYTE;           return true;
    case GL_R8UI:      *format = GL_RED_INTEGER;   *type = GL_UNSIGNED_BYTE;  return true;
    case GL_R16I:      *format = GL_RED_INTEGER;   *type = GL_SHORT;          return true;
    case GL_R16UI:     *format = GL_RED_INTEGER;   *type = GL_UNSIGNED_SHORT; return true;
    case GL_R16F:      *format = GL_RED;           *type = GL_HALF_FLOAT;     return true;
    case GL_R32I:      *format = GL_RED_INTEGER;   *type = GL_INT;            return true;
    case GL_R32UI:     *format = GL_RED_INTEGER;   *type = GL_UNSIGNED_INT;   return true;
    case GL_R32F:      *format = GL_RED;           *type = GL_FLOAT;          return true;

    case GL_RG8:       *format = GL_RG;            *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RG8I:      *format = GL_RG_INTEGER;    *type = GL_BYTE;           return true;
    case GL_RG8UI:     *format = GL_RG_INTEGER;    *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RG16I:     *format = GL_RG_INTEGER;    *type = GL_SHORT;          return true;
    case GL_RG16UI:    *format = GL_RG_INTEGER;    *type = GL_UNSIGNED_SHORT; return true;
    case GL_RG16F:     *format = GL_RG;            *type = GL_HALF_FLOAT;     return true;
    case GL_RG32I:     *format = GL_RG_INTEGER;    *type = GL_INT;            return true;
    case GL_RG32UI:    *format = GL_RG_INTEGER;    *type = GL_UNSIGNED_INT;   return true;
    case GL_RG32F:     *format = GL_RG;            *type = GL_FLOAT;          return true;

    case GL_RGB8:      *format = GL_RGB;           *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RGB8I:     *format = GL_RGB_INTEGER;   *type = GL_BYTE;           return true;
    case GL_RGB8UI:    *format = GL_RGB_INTEGER;   *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RGB16I:    *format = GL_RGB_INTEGER;   *type = GL_SHORT;          return true;
    case GL_RGB16UI:   *format = GL_RGB_INTEGER;   *type = GL_UNSIGNED_SHORT; return true;
    case GL_RGB16F:    *format = GL_RGB;           *type = GL_HALF_FLOAT;     return true;
    case GL_RGB32I:    *format = GL_RGB_INTEGER;   *type = GL_INT;            return true;
    case GL_RGB32UI:   *format = GL_RGB_INTEGER;   *type = GL_UNSIGNED_INT;   return true;
    case GL_RGB32F:    *format = GL_RGB;           *type = GL_FLOAT;          return true;

    case GL_RGBA8:     *format = GL_RGBA;          *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RGBA8I:    *format = GL_RGBA_INTEGER;  *type = GL_BYTE;           return true;
    case GL_RGBA8UI:   *format = GL_RGBA_INTEGER;  *type = GL_UNSIGNED_BYTE;  return true;
    case GL_RGBA16I:   *format = GL_RGBA_INTEGER;  *type = GL_SHORT;          return true;
    case GL_RGBA16UI:  *format = GL_RGBA_INTEGER;  *type = GL_UNSIGNED_SHORT; return true;
    case GL_RGBA16F:   *format = GL_RGBA;          *type = GL_HALF_FLOAT;     return true;
    case GL_RGBA32I:   *format = GL_RGBA_INTEGER;  *type = GL_INT;            return true;
    case GL_RGBA32UI:  *format = GL_RGBA_INTEGER;  *type = GL_UNSIGNED_INT;   return true;
    case GL_RGBA32F:   *format = GL_RGBA;          *type = GL_FLOAT;          return true;
    // clang-format on
    default:
        return false;
    }
}

size_t get_internal_format_size(GLenum internalformat) {
    switch (internalformat) {
    case GL_R8:
        return 1;
    case GL_R8I:
    case GL_R8UI:
        return 1;
    case GL_R16:
        return 2;
    case GL_R16I:
    case GL_R16UI:
    case GL_R16F:
        return 2;
    case GL_R32I:
    case GL_R32UI:
    case GL_R32F:
        return 4;

    case GL_RG8:
        return 2;
    case GL_RG8I:
    case GL_RG8UI:
        return 2;
    case GL_RG16:
        return 4;
    case GL_RG16I:
    case GL_RG16UI:
    case GL_RG16F:
        return 4;
    case GL_RG32I:
    case GL_RG32UI:
    case GL_RG32F:
        return 8;

    case GL_RGB8:
        return 3;
    case GL_RGB8I:
    case GL_RGB8UI:
        return 3;
    case GL_RGB16:
        return 6;
    case GL_RGB16I:
    case GL_RGB16UI:
    case GL_RGB16F:
        return 6;
    case GL_RGB32I:
    case GL_RGB32UI:
    case GL_RGB32F:
        return 12;

    case GL_RGBA8:
        return 4;
    case GL_RGBA8I:
    case GL_RGBA8UI:
        return 4;
    case GL_RGBA16:
        return 8;
    case GL_RGBA16I:
    case GL_RGBA16UI:
    case GL_RGBA16F:
        return 8;
    case GL_RGBA32I:
    case GL_RGBA32UI:
    case GL_RGBA32F:
        return 16;

    case GL_DEPTH_COMPONENT16:
        return 2;
    case GL_DEPTH_COMPONENT24:
        return 3;
    case GL_DEPTH_COMPONENT32:
        return 4;
    case GL_DEPTH_COMPONENT32F:
        return 4;
    case GL_DEPTH24_STENCIL8:
        return 4;
    case GL_DEPTH32F_STENCIL8:
        return 5;

    case GL_STENCIL_INDEX8:
        return 1;

    case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
    case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
        return 8;
    case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
    case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
        return 16;

    default:
        LOG_E("Unknown internal format size for %s", glEnumToString(internalformat));
        return 0;
    }
}

extern std::string bufSampelerName;

// Report a rejected argument once per site. This layer cannot raise a GL error
// -- glGetError always answers GL_NO_ERROR by design -- so an unusable argument
// means "do nothing" plus one line a user can paste into a bug report. LOG_W and
// LOG_E compile to nothing in release builds, hence LOG_W_FORCE.
#define BU_WARN_ONCE(...)                                                                                              \
    do {                                                                                                               \
        static bool mg_bu_warned = false;                                                                              \
        if (!mg_bu_warned) {                                                                                           \
            mg_bu_warned = true;                                                                                       \
            LOG_W_FORCE(__VA_ARGS__)                                                                                   \
        }                                                                                                              \
    } while (0)

// Todo: any glGet* related to this function?

// Copy the CURRENT contents of app_buffer's data store into tex_name, sized for
// internalformat. Saves and restores everything it borrows: the active unit,
// unit 15's GL_TEXTURE_2D binding (several emulated buffer textures can be
// alive at once and a different one may be parked there) and the pixel-unpack
// binding. hard=true is the initial glTexBuffer path and raises
// GL_INVALID_ENUM / GL_INVALID_VALUE exactly as it always did; hard=false is
// the re-upload path, which skips unrepresentable buffers quietly -- the
// previous snapshot is the best available content in that case anyway.
static bool mg_tbo_emulated_upload(GLuint app_buffer, GLuint tex_name, GLenum internalformat, bool hard) {
    GLuint real_buffer = find_real_buffer(app_buffer);
    if (!real_buffer) return false;

    // internalformat arrives unvalidated -- a format outside GL 4.6 table 8.16
    // is GL_INVALID_ENUM in real GL and this layer raises nothing -- so
    // get_internal_format_size answers 0 for it, as its own default case says.
    // That 0 used to reach "bufferSize / pixelSize" below: undefined, and on
    // arm64 it divides to zero, giving a 0 x 1 texture that the emulated
    // texelFetch then indexes modulo zero. Size the texel first and drop the
    // call if we cannot, before any binding is disturbed.
    GLuint pixelSize = get_internal_format_size(internalformat);
    if (pixelSize == 0) {
        BU_WARN_ONCE("glTexBuffer: no texel size known for internalformat %s, texture buffer left untouched",
                     glEnumToString(internalformat));
        if (hard) mg_set_gl_error(GL_INVALID_ENUM);
        return false;
    }

    // The transfer pair this internalformat actually accepts. Hardcoding one
    // pair here is what made every format but GL_R8I fail to allocate.
    GLenum tb_format = GL_RED_INTEGER, tb_type = GL_BYTE;
    if (!get_internal_format_transfer(internalformat, &tb_format, &tb_type)) {
        BU_WARN_ONCE("glTexBuffer: no GLES transfer pair for internalformat %s, texture buffer left untouched",
                     glEnumToString(internalformat));
        if (hard) mg_set_gl_error(GL_INVALID_ENUM);
        return false;
    }

    GLES.glActiveTexture(GL_TEXTURE0 + 15);
    GLint prev_parked = 0;
    GLES.glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev_parked);
    GLint prev_pixel_buffer_binding = 0;
    GLES.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &prev_pixel_buffer_binding);

    GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, real_buffer);
    GLint bufferSize = 0;
    GLES.glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_SIZE, &bufferSize);
    GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

    GLES.glBindTexture(GL_TEXTURE_2D, tex_name);

    const GLuint MAX_WIDTH = 8192;
    GLuint numElements = bufferSize / pixelSize;
    if (numElements == 0) {
        // A buffer too small to hold one texel. The pixelSize == 0 guard above
        // exists because a zero-sized texture makes the emulated texelFetch
        // index modulo zero; this reaches the same place by the other road,
        // through a 0 x 1 glTexImage2D and a u_BufferTexWidth of 0.
        BU_WARN_ONCE("glTexBuffer: buffer of %d bytes holds no %u-byte texel, texture buffer left untouched",
                     bufferSize, pixelSize);
        if (hard) mg_set_gl_error(GL_INVALID_VALUE);
        GLES.glBindTexture(GL_TEXTURE_2D, prev_parked);
        GLES.glActiveTexture(GL_TEXTURE0 + gl_state->current_tex_unit);
        return false;
    }

    GLuint width = numElements;
    GLuint height = 1;

    if (width > MAX_WIDTH) {
        width = MAX_WIDTH;
        height = (numElements + MAX_WIDTH - 1) / MAX_WIDTH;
    }

    GLint prev_alignment, prev_row_length, prev_skip_pixels, prev_skip_rows;
    GLES.glGetIntegerv(GL_UNPACK_ALIGNMENT, &prev_alignment);
    GLES.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &prev_row_length);
    GLES.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &prev_skip_pixels);
    GLES.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &prev_skip_rows);

    // why do these 2 params not work
    // GLES.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    // GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
    GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);

    GLES.glTexImage2D(GL_TEXTURE_2D, 0, internalformat, width, height, 0, tb_format, tb_type, nullptr);

    GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, real_buffer);

    for (GLuint row = 0; row < height; ++row) {
        // The last row is short whenever the element count is not a multiple
        // of the row width. Asking for a full row anyway made the driver read
        // past the end of the unpack buffer, which GLES answers with
        // GL_INVALID_OPERATION and a no-op -- so the tail of the buffer was
        // never uploaded and texelFetch read it back as whatever the
        // allocation left there.
        const GLuint row_texels = (row + 1 == height) ? (numElements - row * width) : width;
        if (row_texels == 0) break;
        void* offset = (void*)(static_cast<size_t>(row) * width * pixelSize);
        GLES.glTexSubImage2D(GL_TEXTURE_2D, 0, 0, row, row_texels, 1, tb_format, tb_type, offset);
    }

    GLES.glPixelStorei(GL_UNPACK_ALIGNMENT, prev_alignment);
    GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH, prev_row_length);
    GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS, prev_skip_pixels);
    GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS, prev_skip_rows);

    if (TextureObject* tex = mgGetTexObjectByID(tex_name)) {
        tex->target = ConvertGLEnumToTextureTarget(GL_TEXTURE_BUFFER);
        tex->internal_format = internalformat;
        tex->width = width;
        tex->height = height;
        tex->depth = 1;
        tex->swizzle_param[0] = GL_RED;
        tex->swizzle_param[1] = GL_GREEN;
        tex->swizzle_param[2] = GL_BLUE;
        tex->swizzle_param[3] = GL_ALPHA;
    }

    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
    GLES.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);

    GLES.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, prev_pixel_buffer_binding);

    // Put back whatever was parked on the emulation unit: re-uploading one
    // buffer texture must not park a different one.
    GLES.glBindTexture(GL_TEXTURE_2D, prev_parked);
    GLES.glActiveTexture(GL_TEXTURE0 + gl_state->current_tex_unit);

    CHECK_GL_ERROR;
    return true;
}

// Re-upload hook for the buffer-mutation entry points: refresh the snapshot
// when the mutated buffer backs an emulated buffer texture. One hash lookup on
// the common (non-TBO) path.
static void mg_tbo_refresh_if_backing(GLuint app_buffer) {
    if (app_buffer == 0) return;
    const auto backing = g_tbo_backing.find(app_buffer);
    if (backing == g_tbo_backing.end()) return;
    LOG_D("Re-uploading emulated buffer texture for buffer %u", app_buffer)
    mg_tbo_emulated_upload(app_buffer, backing->second.tex, backing->second.internalformat, false);
}

void glTexBuffer(GLenum target, GLenum internalformat, GLuint buffer) {
    LOG()
    LOG_D("glTexBuffer, target = %s, internalformat = %s, buffer = %d", glEnumToString(target),
          glEnumToString(internalformat), buffer)
    if (target != GL_TEXTURE_BUFFER) return;

    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glTexBuffer(target, internalformat, buffer);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }

    if (hardware->emulate_texture_buffer) {
        LOG_D("Emulating glTexBuffer");

        GLint boundTexture = 0;
        GLES.glActiveTexture(GL_TEXTURE0 + 15);
        GLES.glGetIntegerv(GL_TEXTURE_BINDING_2D, &boundTexture);
        LOG_D("Current GL_TEXTURE_BINDING_BUFFER = %d", boundTexture);
        // Hand the borrowed unit straight back before anything can observe it:
        // unit 15 is only ever parked with the emulated buffer texture, and
        // leaving it active sent the app's next glBindTexture to unit 15.
        GLES.glActiveTexture(GL_TEXTURE0 + gl_state->current_tex_unit);

        if (!boundTexture) {
            LOG_D("No texture bound to GL_TEXTURE_BUFFER, skipping emulation.");
            return;
        }

        // Upload the snapshot (guards, sizing, row-tail handling and the
        // TextureObject record all live in the helper, which doubles as the
        // re-upload path for the buffer-mutation hooks below).
        if (!mg_tbo_emulated_upload(buffer, static_cast<GLuint>(boundTexture), internalformat, true)) return;

        g_tbo_backing[buffer] = {static_cast<GLuint>(boundTexture), internalformat};
        return;
    }

    GLES.glTexBuffer(target, internalformat, real_buffer);
    CHECK_GL_ERROR
}

void glTexBufferRange(GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    LOG()
    LOG_D("glTexBufferRange, target = %s, internalformat = %s, buffer = %d, offset = %p, size = %zi",
          glEnumToString(target), glEnumToString(internalformat), buffer, (void*)offset, size)
    if (!has_buffer(buffer) || buffer == 0) {
        GLES.glTexBufferRange(target, internalformat, buffer, offset, size);
        CHECK_GL_ERROR
        return;
    }
    GLuint real_buffer = find_real_buffer(buffer);
    if (!real_buffer) {
        GLES.glGenBuffers(1, &real_buffer);
        modify_buffer(buffer, real_buffer);
        CHECK_GL_ERROR
    }
    GLES.glTexBufferRange(target, internalformat, real_buffer, offset, size);
    CHECK_GL_ERROR
}

// GLES has no GL_PARAMETER_BUFFER, so glBindBuffer above tracks the binding
// without ever handing that target to the driver. GL 4.6 still lets an
// application fill and query the buffer through it, which used to reach GLES
// verbatim and come back GL_INVALID_ENUM -- the buffer stayed empty, and
// glMultiDraw*IndirectCount then found a zero-byte parameter buffer and drew
// nothing.
//
// GL_COPY_WRITE_BUFFER is borrowed for the duration of one call and put back
// afterwards. GLES defines it as a generic target with no meaning of its own, so
// the swap is invisible: nothing observes it, and no draw depends on it.
//
// GL_TEXTURE_BUFFER joins it while the buffer-texture emulation is active: an
// ES 3.0/3.1 driver has no such binding point either, and forwarding the target
// answered GL_INVALID_ENUM -- which silently swallowed every mutation MC
// issued against a buffer-texture backing store through that target. (With a
// 3.2+ driver and native glTexBuffer the target still passes straight
// through.)
namespace {
struct borrowed_target_t {
    GLenum target;
    GLint saved = 0;
    bool borrowed = false;

    explicit borrowed_target_t(GLenum requested) : target(requested) {
        const bool borrow = requested == GL_PARAMETER_BUFFER ||
                            (requested == GL_TEXTURE_BUFFER && hardware->emulate_texture_buffer);
        if (!borrow) return;
        const GLuint app_buffer = requested == GL_PARAMETER_BUFFER
                                      ? find_bound_buffer(GL_PARAMETER_BUFFER_BINDING)
                                      : find_bound_buffer_by_target(GL_TEXTURE_BUFFER);
        const GLuint real = find_real_buffer(app_buffer);
        GLES.glGetIntegerv(GL_COPY_WRITE_BUFFER_BINDING, &saved);
        GLES.glBindBuffer(GL_COPY_WRITE_BUFFER, real);
        target = GL_COPY_WRITE_BUFFER;
        borrowed = true;
    }
    ~borrowed_target_t() {
        if (borrowed) GLES.glBindBuffer(GL_COPY_WRITE_BUFFER, static_cast<GLuint>(saved));
    }

    borrowed_target_t(const borrowed_target_t&) = delete;
    borrowed_target_t& operator=(const borrowed_target_t&) = delete;
};
} // namespace

void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    MG_PERF_SCOPE(MGP_BUFFER);
    MG_PERF_BYTES(size);
    LOG()
    LOG_D("glBufferData, target = %s, size = %d, data = 0x%x, usage = %s", glEnumToString(target), size, data,
          glEnumToString(usage))
    ubo_restore_generic_for(target);
    borrowed_target_t t(target);
    GLES.glBufferData(t.target, size, data, usage);
    set_buffer_data_size(find_bound_buffer_by_target(target), size);
    CHECK_GL_ERROR
    ubo_mirror_respecify(find_bound_buffer_by_target(target), static_cast<size_t>(size), data);
    // Storage may have been (re)specified or resized: refresh the emulated
    // buffer-texture snapshot if this buffer backs one.
    if (hardware->emulate_texture_buffer)
        mg_tbo_refresh_if_backing(find_bound_buffer_by_target(target));
}

// Both of these were plain pass-throughs in gl/gl_native.cpp. They live here now
// so that GL_PARAMETER_BUFFER reaches the driver as a target it understands.
// ANGLE's Metal backend uploads into a buffer the GPU is still reading with a
// blit, which never waits -- but only when offset and size are multiples of 4
// (BufferMtl::setSubDataImpl). Anything else falls back to a CPU copy into the
// live buffer, which first submits the GPU's queued work and waits for it to
// finish. Chunk uploads on 26.x hit that and stalled the render thread for
// 30-100 ms at a time (Air's sampler: CommandBuffer::commit under
// glBufferSubData). Such an upload goes into a fresh staging buffer instead and
// is copied across on the GPU; Metal on iOS blits at any byte offset.
//
// Aligned uploads into a large buffer go the same way. For those ANGLE
// usually allocates a whole new Metal buffer the size of the destination,
// copies the new bytes in and blits the rest across
// (putDataInNewBufferAndStartUsingNewBuffer). Sodium's chunk buffers are many
// megabytes, so walking into new chunks allocated 64 MB within moments, and
// ANGLE's buffer manager answers that by waiting for the GPU to finish
// everything (flushCommandBuffer(WaitUntilFinished) in BufferManager::
// getBuffer) -- the choppy chunk loading. Staging allocates only the upload's
// size, from recycled power-of-two buffers.
// MG_UPLOAD_STAGING=0 turns it off.
constexpr size_t kStageLargeBuffer = 1024 * 1024;
static bool mg_stage_upload(GLenum target, size_t dest_size, GLintptr offset, GLsizeiptr size, const void* data) {
    static const bool on = [] {
        const char* e = getenv("MG_UPLOAD_STAGING");
        return !(e && e[0] == '0');
    }();
    if (!on || data == nullptr || offset < 0 || size < 16) return false;
    const bool unaligned = ((offset | size) & 3) != 0;
    if (!unaligned && dest_size < kStageLargeBuffer) return false;
    if (GLES.glCopyBufferSubData == nullptr) return false;
    const GLenum stage_target = target == GL_COPY_READ_BUFFER ? GL_COPY_WRITE_BUFFER : GL_COPY_READ_BUFFER;
    GLuint& stage = g_bc->upload_stage;
    if (stage == 0) GLES.glGenBuffers(1, &stage);
    // Power-of-two sizes so ANGLE's buffer cache, which matches exact sizes,
    // keeps handing back recycled Metal buffers.
    GLsizeiptr bucket = 4096;
    while (bucket < size) bucket <<= 1;
    GLES.glBindBuffer(stage_target, stage);
    // Respecifying gives a Metal buffer the GPU isn't using, so the write
    // below is a plain CPU copy with no wait.
    GLES.glBufferData(stage_target, bucket, nullptr, GL_STREAM_DRAW);
    GLES.glBufferSubData(stage_target, 0, size, data);
    GLES.glCopyBufferSubData(stage_target, target, 0, offset, size);
    GLES.glBindBuffer(stage_target, mg_driver_bound_buffer(stage_target));
    return true;
}

void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    MG_PERF_SCOPE(MGP_BUFFER);
    MG_PERF_BYTES(size);
    LOG()
    LOG_D("glBufferSubData, target = %s, offset = %p, size = %zi", glEnumToString(target), (void*)offset, size)
    ubo_restore_generic_for(target);
    borrowed_target_t t(target);
    if (!mg_stage_upload(t.target, get_buffer_data_size(find_bound_buffer_by_target(target)), offset, size, data))
        GLES.glBufferSubData(t.target, offset, size, data);
    CHECK_GL_ERROR
    if (offset >= 0 && size > 0)
        ubo_mirror_write(find_bound_buffer_by_target(target), static_cast<size_t>(offset), data,
                         static_cast<size_t>(size));
    if (hardware->emulate_texture_buffer)
        mg_tbo_refresh_if_backing(find_bound_buffer_by_target(target));
}

void glGetBufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    LOG()
    LOG_D("glGetBufferParameteriv, target = %s, pname = %s", glEnumToString(target), glEnumToString(pname))
    ubo_restore_generic_for(target);
    borrowed_target_t t(target);
    GLES.glGetBufferParameteriv(t.target, pname, params);
    CHECK_GL_ERROR
}

void* glMapBuffer(GLenum target, GLenum access) {
    MG_PERF_SCOPE(MGP_MAP);
    LOG()
    LOG_D("glMapBuffer, target = %s, access = %s", glEnumToString(target), glEnumToString(access))
    ubo_restore_generic_for(target);
    if (g_gles_caps.GL_OES_mapbuffer) {
        borrowed_target_t t(target);
        void* ptr = GLES.glMapBufferOES(t.target, access);
        const GLuint app = find_bound_buffer_by_target(target);
        ubo_note_map(app, 0, get_buffer_data_size(app), access == GL_READ_ONLY ? 0 : GL_MAP_WRITE_BIT, ptr);
        return ptr;
    }
    GLint buffer_size;
    glGetBufferParameteriv(target, GL_BUFFER_SIZE, &buffer_size);
    if (buffer_size <= 0 || glGetError() != GL_NO_ERROR) {
        return nullptr;
    }
    GLbitfield flags = 0;
    switch (access) {
    case GL_READ_ONLY:
        flags = GL_MAP_READ_BIT;
        break;
    case GL_WRITE_ONLY:
        flags = GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT;
        break;
    case GL_READ_WRITE:
        flags = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
        break;
    default:
        return nullptr;
    }
    void* ptr = glMapBufferRange(target, 0, buffer_size, flags);
    return ptr;
}

#if GLOBAL_DEBUG || DEBUG
#include <fstream>
#define BIN_FILE_PREFIX "/sdcard/MG/buf/"
#endif

#if !defined(__APPLE__)
extern "C"
{
    GLAPI GLAPIENTRY void* glMapBufferARB(GLenum target, GLenum access) __attribute__((alias("glMapBuffer")));
    GLAPI GLAPIENTRY void glBufferDataARB(GLenum target, GLsizeiptr size, const void* data, GLenum usage)
        __attribute__((alias("glBufferData")));
    GLAPI GLAPIENTRY GLboolean glUnmapBufferARB(GLenum target) __attribute__((alias("glUnmapBuffer")));
    GLAPI GLAPIENTRY void glBufferStorageARB(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags)
        __attribute__((alias("glBufferStorage")));
    GLAPI GLAPIENTRY void glBindBufferARB(GLenum target, GLuint buffer) __attribute__((alias("glBindBuffer")));
}
#endif

void* glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    MG_PERF_SCOPE(MGP_MAP);
    LOG()
    if (global_settings.buffer_coherent_as_flush) access &= ~GL_MAP_FLUSH_EXPLICIT_BIT;
    //    access |= GL_MAP_UNSYNCHRONIZED_BIT;
    ubo_restore_generic_for(target);
    borrowed_target_t t(target);
    void* ptr = GLES.glMapBufferRange(t.target, offset, length, access);
    if (offset >= 0 && length > 0)
        ubo_note_map(find_bound_buffer_by_target(target), static_cast<size_t>(offset), static_cast<size_t>(length),
                     access, ptr);
    return ptr;
}

GLboolean glUnmapBuffer(GLenum target) {
    LOG()
    LOG_D("%s(%s)", __func__, glEnumToString(target));
    ubo_restore_generic_for(target);
    // The mapped bytes have to reach the uniform-block mirror before the driver
    // takes the pointer away; proxies are refreshed once it has.
    const GLuint app_buffer = find_bound_buffer_by_target(target);
    size_t written_begin = 0, written_end = 0;
    const bool written = ubo_take_unmap(app_buffer, &written_begin, &written_end);
    borrowed_target_t t(target);
    if (g_gles_caps.GL_OES_mapbuffer) {
        GLboolean r = GLES.glUnmapBuffer(t.target);
        if (written) ubo_refresh_slots(app_buffer, written_begin, written_end);
        return r;
    }

    GLboolean result = GLES.glUnmapBuffer(t.target);
    CHECK_GL_ERROR
    if (written) ubo_refresh_slots(app_buffer, written_begin, written_end);
    // Mapping writes commit at unmap time, so the snapshot is refreshed here.
    if (result && hardware->emulate_texture_buffer)
        mg_tbo_refresh_if_backing(find_bound_buffer_by_target(target));
    return result;
}

void glBufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags) {
    LOG()
    if (GLES.glBufferStorageEXT) {
        if (global_settings.buffer_coherent_as_flush &&
            ((flags & GL_MAP_PERSISTENT_BIT) != 0 || (flags & GL_DYNAMIC_STORAGE_BIT) != 0))
            flags |= (GL_MAP_WRITE_BIT | GL_MAP_COHERENT_BIT | GL_MAP_PERSISTENT_BIT);
        ubo_restore_generic_for(target);
        borrowed_target_t t(target);
        GLES.glBufferStorageEXT(t.target, size, data, flags);
        // Allocates storage just as glBufferData does, so it owes the same record.
        set_buffer_data_size(find_bound_buffer_by_target(target), size);
        // Persistent mappings write without an unmap, which a mirror can't see.
        if (ubo_shadow_t* s = ubo_shadow_of(find_bound_buffer_by_target(target))) s->proxyable = false;
        ubo_mirror_respecify(find_bound_buffer_by_target(target), static_cast<size_t>(size), data);
        if (hardware->emulate_texture_buffer)
            mg_tbo_refresh_if_backing(find_bound_buffer_by_target(target));
    }
    CHECK_GL_ERROR
}

void glFlushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {
    LOG()
    if (!global_settings.buffer_coherent_as_flush) {
        ubo_restore_generic_for(target);
        borrowed_target_t t(target);
        GLES.glFlushMappedBufferRange(t.target, offset, length);
    }
}

// Was a plain pass-through in gl/gl_native.cpp; it lives here so a copy into a
// buffer that backs uniform-block proxies reaches the CPU mirror.
void glCopyBufferSubData(GLenum readTarget, GLenum writeTarget, GLintptr readOffset, GLintptr writeOffset,
                         GLsizeiptr size) {
    LOG()
    ubo_restore_generic_for(readTarget);
    ubo_restore_generic_for(writeTarget);
    GLES.glCopyBufferSubData(readTarget, writeTarget, readOffset, writeOffset, size);
    CHECK_GL_ERROR
    if (size <= 0 || readOffset < 0 || writeOffset < 0) return;
    const GLuint dst = find_bound_buffer_by_target(writeTarget);
    ubo_shadow_t* d = ubo_shadow_of(dst);
    if (!d) return;
    const size_t ro = static_cast<size_t>(readOffset), wo = static_cast<size_t>(writeOffset);
    const size_t n = static_cast<size_t>(size);
    ubo_shadow_t* s = ubo_shadow_of(find_bound_buffer_by_target(readTarget));
    if (d->valid && s && s->valid && ro + n <= s->bytes.size() && wo + n <= d->bytes.size()) {
        memmove(d->bytes.data() + wo, s->bytes.data() + ro, n);
    } else {
        d->valid = false; // re-read from the driver when next needed
    }
    ubo_refresh_slots(dst, wo, wo + n);
}

void glGenVertexArrays(GLsizei n, GLuint* arrays) {
    LOG()
    LOG_D("glGenVertexArrays(%i, %p)", n, arrays)
    for (int i = 0; i < n; ++i) {
        arrays[i] = gen_array();
    }
}

void glDeleteVertexArrays(GLsizei n, const GLuint* arrays) {
    LOG()
    LOG_D("glDeleteVertexArrays(%i, %p)", n, arrays)
    for (int i = 0; i < n; ++i) {
        if (find_real_array(arrays[i])) {
            GLuint real_array = find_real_array(arrays[i]);
            GLES.glDeleteVertexArrays(1, &real_array);
            CHECK_GL_ERROR
        }
        remove_array(arrays[i]);
    }
}

GLboolean glIsVertexArray(GLuint array) {
    LOG()
    LOG_D("glIsVertexArray(%d)", array)
    return has_array(array);
}

void glBindVertexArray(GLuint array) {
    LOG()
    LOG_D("glBindVertexArray(%d)", array)
    bound_array = array;

    // update bound ibo
    set_bound_buffer_by_target(GL_ELEMENT_ARRAY_BUFFER, get_ibo_by_vao(array));

    if (!has_array(array) || array == 0) {
        LOG_D("Does not have va=%d found!", array)
        GLES.glBindVertexArray(array);
        CHECK_GL_ERROR
        return;
    }

    GLuint real_array = find_real_array(array);
    if (!real_array) {
        LOG_D("va=%d not initialized, initializing...", array)
        GLES.glGenVertexArrays(1, &real_array);
        modify_array(array, real_array);
        CHECK_GL_ERROR
    }
    LOG_D("glBindVertexArray: %d -> %d", array, real_array)
    GLES.glBindVertexArray(real_array);
    CHECK_GL_ERROR
}
