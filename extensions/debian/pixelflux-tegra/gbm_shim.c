/* Mesa 21.2 in focal has no gbm_bo_create_with_modifiers2, which pixelflux links
 * for the Wayland dmabuf path. We capture X11, so that path never runs; the stub
 * exists only to let the module load. Returning NULL is what the real function
 * does when it cannot allocate, so callers already handle it.
 */
#include <stddef.h>
#include <stdint.h>

void *gbm_bo_create_with_modifiers2(void *gbm, uint32_t width, uint32_t height,
                                    uint32_t format, const uint64_t *modifiers,
                                    unsigned int count, uint32_t flags) {
    (void)gbm; (void)width; (void)height; (void)format;
    (void)modifiers; (void)count; (void)flags;
    return NULL;
}
