#include "AvatarMesher.h"
#include <dispatch/dispatch.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static inline float clampf(float x, float a, float b) { return x < a ? a : (x > b ? b : x); }
static inline float smoothstepf(float a, float b, float x) { float t = clampf((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
static inline float signf(float x) { return x > 0 ? 1.0f : (x < 0 ? -1.0f : 0.0f); }
static inline float len3(float x, float y, float z) { return sqrtf(x * x + y * y + z * z); }
static inline float dot3(const float *a, const float *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }

static inline float smin(float a, float b, float k) {
    if (k <= 0) return fminf(a, b);
    float h = fmaxf(k - fabsf(a - b), 0) / k;
    return fminf(a, b) - h * h * k * 0.25f;
}
static inline float smax(float a, float b, float k) { return -smin(-a, -b, k); }

static inline float ellipsoid(float qx, float qy, float qz, const float *r) {
    float k1 = len3(qx / (r[0] * r[0]), qy / (r[1] * r[1]), qz / (r[2] * r[2]));
    if (k1 < 1e-9f) return -fminf(r[0], fminf(r[1], r[2]));
    float k0 = len3(qx / r[0], qy / r[1], qz / r[2]);
    return k0 * (k0 - 1) / k1;
}

static inline float round_cone(const float *p, const float *a, const float *b, float r1, float r2) {
    float ba[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    float l2 = dot3(ba, ba);
    float rr = r1 - r2;
    float a2 = l2 - rr * rr;
    float il2 = 1 / l2;
    float pa[3] = { p[0] - a[0], p[1] - a[1], p[2] - a[2] };
    float y = dot3(pa, ba);
    float z = y - l2;
    float xv[3] = { pa[0] * l2 - ba[0] * y, pa[1] * l2 - ba[1] * y, pa[2] * l2 - ba[2] * y };
    float x2 = dot3(xv, xv);
    float y2 = y * y * l2;
    float z2 = z * z * l2;
    float k = signf(rr) * rr * rr * x2;
    if (signf(z) * a2 * z2 > k) return sqrtf(x2 + z2) * il2 - r2;
    if (signf(y) * a2 * y2 < k) return sqrtf(x2 + y2) * il2 - r1;
    return (sqrtf(x2 * a2 * il2) + y * rr) * il2 - r1;
}

static inline float shape_distance(const FMShape *s, const float *p) {
    switch (s->kind) {
    case FM_ELLIPSOID: {
        float d[3] = { p[0] - s->centre[0], p[1] - s->centre[1], p[2] - s->centre[2] };
        const float *m = s->toLocal;
        return ellipsoid(m[0] * d[0] + m[1] * d[1] + m[2] * d[2], m[3] * d[0] + m[4] * d[1] + m[5] * d[2],
                         m[6] * d[0] + m[7] * d[1] + m[8] * d[2], s->radii);
    }
    case FM_ROUND_CONE:
        return round_cone(p, s->centre, s->end, s->ra, s->rb);
    default: {
        float e = ellipsoid(p[0] - s->centre[0], p[1] - s->centre[1], p[2] - s->centre[2], s->radii);
        float q[3] = { p[0] - s->planePoint[0], p[1] - s->planePoint[1], p[2] - s->planePoint[2] };
        return smax(e, -dot3(q, s->planeNormal), s->capK);
    }
    }
}

static float combine(const FMShape *shapes, int count, const float *p) {
    float d = FLT_MAX;
    for (int i = 0; i < count; i++) {
        const FMShape *s = &shapes[i];
        // Shapes too far away to change the result are skipped: much faster, and exact.
        float lower = len3(p[0] - s->boundCentre[0], p[1] - s->boundCentre[1], p[2] - s->boundCentre[2]) - s->boundRadius;
        if (s->op == FM_UNION) {
            if (lower - d > s->k) continue;
            d = smin(d, shape_distance(s, p), s->k);
        } else {
            if (lower > -d + s->k) continue;
            d = smax(d, -shape_distance(s, p), s->k);
        }
    }
    return d;
}

float fm_distance(const FMField *field, const float p[3]) {
    float d = combine(field->groups[0].shapes, field->groups[0].count, p);
    for (int g = 1; g < field->count; g++) {
        const FMGroup *limb = &field->groups[g];
        float toJoint = len3(p[0] - limb->joint[0], p[1] - limb->joint[1], p[2] - limb->joint[2]);
        float k = limb->blendK * (1 - smoothstepf(limb->blendRadius * 0.5f, limb->blendRadius, toJoint));
        float lower = len3(p[0] - limb->boundCentre[0], p[1] - limb->boundCentre[1], p[2] - limb->boundCentre[2]) - limb->boundRadius;
        if (lower - d > k) continue;
        d = smin(d, combine(limb->shapes, limb->count, p), k);
    }
    return fmaxf(d, -p[1]);   // flat soles: nothing below the floor
}

int32_t fm_part(const FMField *field, const float p[3]) {
    int best = 0;
    float bestDistance = combine(field->groups[0].shapes, field->groups[0].count, p);
    for (int g = 1; g < field->count; g++) {
        const FMGroup *limb = &field->groups[g];
        float lower = len3(p[0] - limb->boundCentre[0], p[1] - limb->boundCentre[1], p[2] - limb->boundCentre[2]) - limb->boundRadius;
        if (lower > bestDistance) continue;
        float d = combine(limb->shapes, limb->count, p);
        if (d < bestDistance) { bestDistance = d; best = g; }
    }
    return best;
}

void fm_gradient(const FMField *field, const float p[3], float e, float out[3]) {
    float q[3];
    float g[3];
    for (int axis = 0; axis < 3; axis++) {
        memcpy(q, p, sizeof q); q[axis] += e;
        float a = fm_distance(field, q);
        q[axis] = p[axis] - e;
        g[axis] = a - fm_distance(field, q);
    }
    float l = len3(g[0], g[1], g[2]);
    if (l > 1e-12f) { out[0] = g[0] / l; out[1] = g[1] / l; out[2] = g[2] / l; }
    else { out[0] = 0; out[1] = 1; out[2] = 0; }
}

// Growable arrays.
typedef struct { float *data; size_t count, capacity; } FloatList;
typedef struct { uint32_t *data; size_t count, capacity; } IndexList;
static int float_push3(FloatList *l, float x, float y, float z) {
    if (l->count + 3 > l->capacity) {
        size_t c = l->capacity ? l->capacity * 2 : 3 * 65536;
        float *d = realloc(l->data, c * sizeof(float));
        if (!d) return -1;
        l->data = d; l->capacity = c;
    }
    l->data[l->count++] = x; l->data[l->count++] = y; l->data[l->count++] = z;
    return 0;
}
static int index_push(IndexList *l, uint32_t v) {
    if (l->count + 1 > l->capacity) {
        size_t c = l->capacity ? l->capacity * 2 : 6 * 65536;
        uint32_t *d = realloc(l->data, c * sizeof(uint32_t));
        if (!d) return -1;
        l->data = d; l->capacity = c;
    }
    l->data[l->count++] = v;
    return 0;
}

static void emit(const float *pos, IndexList *out, int32_t q0, int32_t q1, int32_t q2, int32_t q3, int axis, float direction) {
    if (q0 < 0 || q1 < 0 || q2 < 0 || q3 < 0) return;
    const float *a = pos + 3 * q0, *b = pos + 3 * q1, *c = pos + 3 * q2, *d = pos + 3 * q3;
    float ab[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, ac[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    float ad[3] = { d[0] - a[0], d[1] - a[1], d[2] - a[2] };
    float n1[3] = { ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0] };
    float n2[3] = { ac[1] * ad[2] - ac[2] * ad[1], ac[2] * ad[0] - ac[0] * ad[2], ac[0] * ad[1] - ac[1] * ad[0] };
    float facing = (n1[axis] + n2[axis]) * direction;
    if (facing >= 0) {
        index_push(out, q0); index_push(out, q1); index_push(out, q2);
        index_push(out, q0); index_push(out, q2); index_push(out, q3);
    } else {
        index_push(out, q0); index_push(out, q3); index_push(out, q2);
        index_push(out, q0); index_push(out, q2); index_push(out, q1);
    }
}

int32_t fm_surface_nets(const FMField *field, const float lo[3], const float hi[3], float h, FMMesh *out) {
    memset(out, 0, sizeof *out);
    const int nx = (int)ceilf((hi[0] - lo[0]) / h) + 1;
    const int ny = (int)ceilf((hi[1] - lo[1]) / h) + 1;
    const int nz = (int)ceilf((hi[2] - lo[2]) / h) + 1;
    const size_t total = (size_t)nx * ny * nz;

    // 1. Sample the field: a coarse pass finds the surface, then only nearby points get an exact value.
    const int c = 4;
    const int cx = (nx - 1) / c + 2, cy = (ny - 1) / c + 2, cz = (nz - 1) / c + 2;
    float *coarse = malloc(sizeof(float) * (size_t)cx * cy * cz);
    float *values = malloc(sizeof(float) * total);
    if (!coarse || !values) { free(coarse); free(values); return -1; }
    float lx = lo[0], ly = lo[1], lz = lo[2];
    dispatch_apply((size_t)cz, DISPATCH_APPLY_AUTO, ^(size_t k) {
        for (int j = 0; j < cy; j++) for (int i = 0; i < cx; i++) {
            float p[3] = { lx + (float)(i * c) * h, ly + (float)(j * c) * h, lz + (float)((int)k * c) * h };
            coarse[i + cx * (j + cy * (int)k)] = fm_distance(field, p);
        }
    });
    const float farEnough = 4.6f * h;
    dispatch_apply((size_t)nz, DISPATCH_APPLY_AUTO, ^(size_t kk) {
        int k = (int)kk;
        int kc = (k + c / 2) / c; if (kc > cz - 1) kc = cz - 1;
        for (int j = 0; j < ny; j++) {
            int jc = (j + c / 2) / c; if (jc > cy - 1) jc = cy - 1;
            for (int i = 0; i < nx; i++) {
                int ic = (i + c / 2) / c; if (ic > cx - 1) ic = cx - 1;
                float estimate = coarse[ic + cx * (jc + cy * kc)];
                size_t index = (size_t)i + (size_t)nx * ((size_t)j + (size_t)ny * k);
                if (fabsf(estimate) > farEnough) { values[index] = estimate; continue; }
                float p[3] = { lx + i * h, ly + j * h, lz + k * h };
                values[index] = fm_distance(field, p);
            }
        }
    });
    free(coarse);

    // 2. One vertex per cell the surface passes through, at the average of its edge crossings.
    const int cnx = nx - 1, cny = ny - 1, cnz = nz - 1;
    int32_t *cellVertex = malloc(sizeof(int32_t) * (size_t)cnx * cny * cnz);
    if (!cellVertex) { free(values); return -1; }
    FloatList positions = { 0 };
    static const int edges[12][2] = { {0,1},{2,3},{4,5},{6,7},{0,2},{1,3},{4,6},{5,7},{0,4},{1,5},{2,6},{3,7} };
    const size_t sx = 1, sy = (size_t)nx, sz = (size_t)nx * ny;
    for (int k = 0; k < cnz; k++) for (int j = 0; j < cny; j++) for (int i = 0; i < cnx; i++) {
        size_t base = (size_t)i + sy * j + sz * k;
        float v[8] = { values[base], values[base + sx], values[base + sy], values[base + sy + sx],
                       values[base + sz], values[base + sz + sx], values[base + sz + sy], values[base + sz + sy + sx] };
        size_t cell = (size_t)i + (size_t)cnx * ((size_t)j + (size_t)cny * k);
        int inside = 0;
        for (int b = 0; b < 8; b++) inside += v[b] < 0;
        if (inside == 0 || inside == 8) { cellVertex[cell] = -1; continue; }
        float sum[3] = { 0, 0, 0 }; float count = 0;
        for (int e = 0; e < 12; e++) {
            int a = edges[e][0], b = edges[e][1];
            if ((v[a] < 0) == (v[b] < 0)) continue;
            float t = v[a] / (v[a] - v[b]);
            float ax = (float)(a & 1), ay = (float)((a >> 1) & 1), az = (float)((a >> 2) & 1);
            float bx = (float)(b & 1), by = (float)((b >> 1) & 1), bz = (float)((b >> 2) & 1);
            sum[0] += ax + (bx - ax) * t; sum[1] += ay + (by - ay) * t; sum[2] += az + (bz - az) * t;
            count += 1;
        }
        cellVertex[cell] = (int32_t)(positions.count / 3);
        if (float_push3(&positions, lx + (i + sum[0] / count) * h, ly + (j + sum[1] / count) * h, lz + (k + sum[2] / count) * h) != 0) {
            free(values); free(cellVertex); free(positions.data); return -1;
        }
    }

    // 3. A quad for every grid edge that crosses the surface, joining the four cells around it.
    IndexList indices = { 0 };
    #define CELL(i, j, k) cellVertex[(size_t)(i) + (size_t)cnx * ((size_t)(j) + (size_t)cny * (size_t)(k))]
    for (int k = 0; k < nz; k++) for (int j = 0; j < ny; j++) for (int i = 0; i < nx; i++) {
        size_t index = (size_t)i + sy * j + sz * k;
        int in = values[index] < 0;
        float direction = in ? 1.0f : -1.0f;
        if (i < nx - 1 && j >= 1 && k >= 1 && j < ny - 1 && k < nz - 1 && in != (values[index + sx] < 0))
            emit(positions.data, &indices, CELL(i, j - 1, k - 1), CELL(i, j, k - 1), CELL(i, j, k), CELL(i, j - 1, k), 0, direction);
        if (j < ny - 1 && i >= 1 && k >= 1 && i < nx - 1 && k < nz - 1 && in != (values[index + sy] < 0))
            emit(positions.data, &indices, CELL(i - 1, j, k - 1), CELL(i, j, k - 1), CELL(i, j, k), CELL(i - 1, j, k), 1, direction);
        if (k < nz - 1 && i >= 1 && j >= 1 && i < nx - 1 && j < ny - 1 && in != (values[index + sz] < 0))
            emit(positions.data, &indices, CELL(i - 1, j - 1, k), CELL(i, j - 1, k), CELL(i, j, k), CELL(i - 1, j, k), 2, direction);
    }
    #undef CELL
    free(values);
    free(cellVertex);

    // 4. Pull each vertex onto the true surface, and take its normal from the field.
    const int vertexCount = (int)(positions.count / 3);
    float *normals = malloc(sizeof(float) * 3 * (size_t)(vertexCount > 0 ? vertexCount : 1));
    if (!normals) { free(positions.data); free(indices.data); return -1; }
    float *pos = positions.data;
    const int chunk = 2048;
    dispatch_apply((size_t)((vertexCount + chunk - 1) / chunk), DISPATCH_APPLY_AUTO, ^(size_t ci) {
        int end = (int)(ci + 1) * chunk; if (end > vertexCount) end = vertexCount;
        for (int v = (int)ci * chunk; v < end; v++) {
            float *q = pos + 3 * v;
            float g[3];
            for (int it = 0; it < 2; it++) {
                float d = clampf(fm_distance(field, q), -h, h);
                fm_gradient(field, q, h * 0.5f, g);
                q[0] -= g[0] * d; q[1] -= g[1] * d; q[2] -= g[2] * d;
            }
            fm_gradient(field, q, h * 0.5f, normals + 3 * v);
        }
    });

    out->positions = positions.data;
    out->normals = normals;
    out->vertexCount = vertexCount;
    out->indices = indices.data;
    out->indexCount = (int32_t)indices.count;
    return 0;
}

void fm_mesh_free(FMMesh *mesh) {
    free(mesh->positions); free(mesh->normals); free(mesh->indices);
    memset(mesh, 0, sizeof *mesh);
}
