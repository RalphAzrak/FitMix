#ifndef AvatarMesher_h
#define AvatarMesher_h

#include <stdint.h>

// The avatar's body field and mesher, in C so it runs fast in unoptimised Debug builds as well as Release.

enum { FM_ELLIPSOID = 0, FM_ROUND_CONE = 1, FM_CAPPED_ELLIPSOID = 2 };
enum { FM_UNION = 0, FM_SUBTRACT = 1 };

typedef struct {
    int32_t kind;
    int32_t op;
    float k;
    float boundCentre[3];
    float boundRadius;
    float centre[3];      // ellipsoid centre, or cone start
    float radii[3];       // ellipsoid radii
    float toLocal[9];     // ellipsoid rotation, row-major
    float end[3];         // cone end
    float ra, rb;         // cone radii
    float planePoint[3];  // capped ellipsoid plane
    float planeNormal[3];
    float capK;
} FMShape;

typedef struct {
    const FMShape *shapes;
    int32_t count;
    float joint[3];
    float blendK;
    float blendRadius;
    float boundCentre[3];
    float boundRadius;
} FMGroup;

/// groups[0] is the torso and head; the rest are limbs that join it near their joint.
typedef struct {
    const FMGroup *groups;
    int32_t count;
} FMField;

typedef struct {
    float *positions;   // xyz per vertex
    float *normals;     // xyz per vertex
    int32_t vertexCount;
    uint32_t *indices;
    int32_t indexCount;
} FMMesh;

float fm_distance(const FMField *field, const float p[3]);
int32_t fm_part(const FMField *field, const float p[3]);
void fm_gradient(const FMField *field, const float p[3], float e, float out[3]);

/// Builds a closed mesh of the surface. Returns 0 on success; free the result with fm_mesh_free.
int32_t fm_surface_nets(const FMField *field, const float lo[3], const float hi[3], float step, FMMesh *out);
void fm_mesh_free(FMMesh *mesh);

#endif
