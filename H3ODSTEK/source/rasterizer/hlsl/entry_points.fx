#include "clip_plane.fx"
#include "dynamic_light_clip.fx"
#include "stipple.fx"

//#ifndef pc
#define ALPHA_OPTIMIZATION
//#endif

#ifndef APPLY_OVERLAYS
#define APPLY_OVERLAYS(color, texcoord, view_dot_normal)
#endif // APPLY_OVERLAYS

PARAM_SAMPLER_2D(radiance_map);

PARAM_SAMPLER_2D(dynamic_light_gel_texture);
//float4 dynamic_light_gel_texture_xform;		// no way to extern this, so I replace it with p_dynamic_light_gel_xform which is aliased on p_lighting_constant_4


float3 get_constant_analytical_light_dir_vs()
{
 	return -normalize(v_lighting_constant_1.xyz + v_lighting_constant_2.xyz + v_lighting_constant_3.xyz);		// ###ctchou $PERF : pass this in as a constant
}


void get_albedo_and_normal(out float3 bump_normal, out float4 albedo, in float2 texcoord, in float3x3 tangent_frame, in float3 fragment_to_camera_world, in float2 fragment_position)
{
#ifdef maybe_calc_albedo
	if (actually_calc_albedo)					// transparent objects must generate their own albedo + normal
	{
		calc_bumpmap_ps(texcoord, fragment_to_camera_world, tangent_frame, bump_normal);
		calc_albedo_ps(texcoord, albedo, bump_normal);
	}
	else		
#endif
	{
#ifndef pc
		fragment_position.xy+= p_tiling_vpos_offset.xy;
#endif

#if DX_VERSION == 11
		int3 fragment_position_int = int3(fragment_position.xy, 0);
		bump_normal = normal_texture.Load(fragment_position_int) * 2.0f - 1.0f;
		albedo = albedo_texture.Load(fragment_position_int);
#elif defined(pc)
		float2 screen_texcoord= (fragment_position.xy + float2(0.5f, 0.5f)) / texture_size.xy;
		bump_normal= sample2D(normal_texture, screen_texcoord).xyz * 2.0f - 1.0f;
		albedo= sample2D(albedo_texture, screen_texcoord);
#else // xenon
		float2 screen_texcoord= fragment_position.xy;
		float4 bump_value;
		asm {
			tfetch2D bump_value, screen_texcoord, normal_texture, AnisoFilter= disabled, MagFilter= point, MinFilter= point, MipFilter= point, UnnormalizedTextureCoords= true, FetchValidOnly= false
			tfetch2D albedo, screen_texcoord, albedo_texture, AnisoFilter= disabled, MagFilter= point, MinFilter= point, MipFilter= point, UnnormalizedTextureCoords= true
		};
		bump_normal= bump_value.xyz * 2.0f - 1.0f;
#endif // xenon
	}
}


#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void albedo_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float4 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float3 fragment_to_camera_world : TEXCOORD4)
{
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position, true);
	
	// normal, tangent and binormal are all in world space
	normal.xyz= vertex.normal;
	normal.w= position.w;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space vector from vertex to eye/camera
	fragment_to_camera_world= Camera_Position - vertex.position;
	
	CALC_CLIP(position);
}

albedo_pixel albedo_ps(
	SCREEN_POSITION_INPUT(screen_position),
	CLIP_INPUT
	in float2 original_texcoord : TEXCOORD0,
	in float4 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float3 fragment_to_camera_world : TEXCOORD4)
{
	// normalize interpolated values
	
#ifndef ALPHA_OPTIMIZATION
	normal.xyz= normalize(normal.xyz);
	binormal= normalize(binormal);
	tangent= normalize(tangent);
#endif

	float3 view_dir= normalize(fragment_to_camera_world);
	
	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal.xyz};
	
	// convert view direction from world space to tangent space
	float3 view_dir_in_tangent_space= mul(tangent_frame, view_dir);
	
	// compute parallax
	float2 texcoord;
	calc_parallax_ps(original_texcoord, view_dir_in_tangent_space, texcoord);

	float output_alpha;
	// do alpha test
	calc_alpha_test_ps(texcoord, output_alpha);
	
   	// compute the bump normal in world_space
	float3 bump_normal;
	calc_bumpmap_ps(texcoord, fragment_to_camera_world, tangent_frame, bump_normal);
	
	float4 albedo;
	calc_albedo_ps(texcoord, albedo, bump_normal);
	
#ifndef NO_ALPHA_TO_COVERAGE
	albedo.w= 1.f;
#endif
	
	return convert_to_albedo_target(albedo, bump_normal, normal.w);
}



#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_default_vs(
	in vertex_type vertex, 
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float4 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float3 fragment_to_camera_world : TEXCOORD4)
{
	albedo_vs(
		vertex, 
		position, 
		CLIP_OUTPUT_PARAM
		texcoord, 
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world);
}

accum_pixel static_default_ps(
	SCREEN_POSITION_INPUT(screen_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0,
	in float4 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float3 fragment_to_camera_world : TEXCOORD4)
{
	albedo_pixel result= albedo_ps(
		screen_position, 
		CLIP_INPUT_PARAM
		texcoord, 
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world);
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(result.albedo_specmask, true, false);
}

float4 calc_output_color_with_explicit_light_quadratic(
	float2 fragment_position,
	float3x3 tangent_frame,				// = {tangent, binormal, normal};
	float4 sh_lighting_coefficients[10],
	float3 fragment_to_camera_world,	// direction to eye/camera, in world space
	float2 original_texcoord,
	float4 prt_ravi_diff,
	float3 light_direction,
	float3 light_intensity,
	float3 extinction,
	float3 inscatter)
{
	float3 view_dir= normalize(fragment_to_camera_world);

	// convert view direction to tangent space
	float3 view_dir_in_tangent_space= mul(tangent_frame, view_dir);
	
	// compute parallax
	float2 texcoord;
	calc_parallax_ps(original_texcoord, view_dir_in_tangent_space, texcoord);

	float output_alpha;
	// do alpha test
	calc_alpha_test_ps(texcoord, output_alpha);

	// get diffuse albedo, specular mask and bump normal
	float3 bump_normal;
	float4 albedo;	
	get_albedo_and_normal(bump_normal, albedo, texcoord, tangent_frame, fragment_to_camera_world, fragment_position);
	
	// compute a blended normal attenuation factor from the length squared of the normal vector
	// blended normal pixels are MSAA pixels that contained normal samples from two different polygons, therefore the lerped vector upon resolve does not have a length of 1.0
	float normal_lengthsq= dot(bump_normal.xyz, bump_normal.xyz);
#ifndef pc	
	float blended_normal_attenuate= pow(normal_lengthsq, 8);
	light_intensity*= blended_normal_attenuate;
#endif

	// normalize bump to make sure specular is smooth as a baby's bottom	
	bump_normal /= sqrt(normal_lengthsq);

	float specular_mask;
	calc_specular_mask_ps(texcoord, albedo.w, specular_mask);
	
	// calculate view reflection direction (in world space of course)
	float view_dot_normal=	dot(view_dir, bump_normal);
	///  DESC: 18 7 2007   12:50 BUNGIE\yaohhu :
	///    We don't need to normalize view_reflect_dir, as long as bump_normal and view_dir have been normalized
	/// float3 view_reflect_dir= normalize( (view_dot_normal * bump_normal - view_dir) * 2 + view_dir );
	float3 view_reflect_dir= (view_dot_normal * bump_normal - view_dir) * 2 + view_dir;

	float4 envmap_specular_reflectance_and_roughness;
	float3 envmap_area_specular_only;
	float4 specular_radiance;
	float3 diffuse_radiance= ravi_order_3(bump_normal, sh_lighting_coefficients);
	
	//float4 lightint_coefficients[4]= {sh_lighting_coefficients[0], sh_lighting_coefficients[1], sh_lighting_coefficients[2], sh_lighting_coefficients[3]};
	
	CALC_MATERIAL(material_type)(
		view_dir,						// normalized
		fragment_to_camera_world,		// actual vector, not normalized
		bump_normal,					// normalized
		view_reflect_dir,				// normalized
		
		sh_lighting_coefficients,	
		light_direction,				// normalized
		light_intensity,
		
		albedo.xyz,					// diffuse_reflectance
		specular_mask,
		texcoord,
		prt_ravi_diff,

		tangent_frame,

		envmap_specular_reflectance_and_roughness,
		envmap_area_specular_only,
		specular_radiance,
		diffuse_radiance);
		
	//compute environment map
	envmap_area_specular_only= max(envmap_area_specular_only, 0.001f);
	float3 envmap_radiance= CALC_ENVMAP(envmap_type)(view_dir, bump_normal, view_reflect_dir, envmap_specular_reflectance_and_roughness, envmap_area_specular_only);

	//compute self illumination	
	float3 self_illum_radiance= calc_self_illumination_ps(texcoord, albedo.xyz, view_dir_in_tangent_space, fragment_position, fragment_to_camera_world, view_dot_normal) * ILLUM_SCALE;
	
	float4 out_color;
	
	// set color channels
#ifdef BLEND_MULTIPLICATIVE
	out_color.xyz= (albedo.xyz + self_illum_radiance);		// No lighting, no fog, no exposure
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= out_color.xyz * BLEND_MULTIPLICATIVE;
	out_color.w= ALPHA_CHANNEL_OUTPUT;
#elif defined(BLEND_FRESNEL)
	out_color.xyz= (diffuse_radiance 
#ifndef _PBR_FX_
					* albedo.xyz
#endif 
					* albedo.w + self_illum_radiance + envmap_radiance + specular_radiance);
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= (out_color.xyz * extinction + inscatter * BLEND_FOG_INSCATTER_SCALE) * g_exposure.rrr;
	out_color.w= saturate(specular_radiance.w + albedo.w);
#else
	out_color.xyz= (diffuse_radiance
#ifndef _PBR_FX_		
	 				* albedo.xyz 
#endif
					+ specular_radiance + self_illum_radiance + envmap_radiance);
	 
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= (out_color.xyz * extinction + inscatter * BLEND_FOG_INSCATTER_SCALE) * g_exposure.rrr;
	out_color.w= ALPHA_CHANNEL_OUTPUT;
#endif
		

	return out_color;
}
	

float4 calc_output_color_with_explicit_light_linear_with_dominant_light(
	float2 fragment_position,
	float3x3 tangent_frame,				// = {tangent, binormal, normal};
	float4 sh_lighting_coefficients[4],
	float3 fragment_to_camera_world,	// direction to eye/camera, in world space
	float2 original_texcoord,
	float4 prt_ravi_diff,
	float3 light_direction,
	float3 light_intensity,
	float3 extinction,
	float3 inscatter)
{

	float3 view_dir= normalize(fragment_to_camera_world);

	// convert view direction to tangent space
	float3 view_dir_in_tangent_space= mul(tangent_frame, view_dir);
	
	// compute parallax
	float2 texcoord;
	calc_parallax_ps(original_texcoord, view_dir_in_tangent_space, texcoord);

	float output_alpha;
	// do alpha test
	calc_alpha_test_ps(texcoord, output_alpha);

	// get diffuse albedo, specular mask and bump normal
	float3 bump_normal;
	float4 albedo;	
	get_albedo_and_normal(bump_normal, albedo, texcoord, tangent_frame, fragment_to_camera_world, fragment_position);
	
	// compute a blended normal attenuation factor from the length squared of the normal vector
	// blended normal pixels are MSAA pixels that contained normal samples from two different polygons, therefore the lerped vector upon resolve does not have a length of 1.0
	float normal_lengthsq= dot(bump_normal.xyz, bump_normal.xyz);
#ifndef pc	
   // PC normals are denormalized due to 8888 format
	float blended_normal_attenuate= pow(normal_lengthsq, 8);
	light_intensity*= blended_normal_attenuate;
#endif

	///  DESC: 20 7 2007   19:54 BUNGIE\yaohhu :
	///   normalize normal to avoid band effect for specular
	bump_normal/=sqrt(normal_lengthsq);

	float specular_mask;
	///  DESC: 11 7 2007   18:1 BUNGIE\yaohhu :
	///     Denomalized normal (averaged in AA) will cause artifact (raid bug 44328)
	///     Not perfect, when demoanized only a little, like the wire's top on the ground
	///     We still have problem. Hard to fix theoritically. We can only hack. 
	///     This is my hack:
#ifndef pc	
	if(normal_lengthsq>=1-1e-2f)
	{
    	calc_specular_mask_ps(texcoord, albedo.w, specular_mask);
    }else{
        specular_mask=0;
    }
#else    
   // No MSAA on PC and normals are denormalized due to 8888 format
 	calc_specular_mask_ps(texcoord, albedo.w, specular_mask);
#endif

	// calculate view reflection direction (in world space of course)
	float view_dot_normal=	dot(view_dir, bump_normal);
	///  DESC: 18 7 2007   12:50 BUNGIE\yaohhu :
	///    We don't need to normalize view_reflect_dir, as long as bump_normal and view_dir have been normalized
	/// float3 view_reflect_dir= normalize( (view_dot_normal * bump_normal - view_dir) * 2 + view_dir );
	float3 view_reflect_dir= (view_dot_normal * bump_normal - view_dir) * 2 + view_dir;

	float4 envmap_specular_reflectance_and_roughness;
	float3 envmap_area_specular_only;
	float4 specular_radiance;
	float3 diffuse_radiance= ravi_order_2_with_dominant_light(bump_normal, sh_lighting_coefficients, light_direction, light_intensity);
	
	float4 zero_vec= 0.0f;
	float4 lightint_coefficients[10]= {
		sh_lighting_coefficients[0],
		sh_lighting_coefficients[1],
		sh_lighting_coefficients[2],
		sh_lighting_coefficients[3],
		zero_vec,
		zero_vec,
		zero_vec,
		zero_vec,
		zero_vec,
		zero_vec};

	CALC_MATERIAL(material_type)(
		view_dir,						// normalized
		fragment_to_camera_world,		// actual vector, not normalized
		bump_normal,					// normalized
		view_reflect_dir,				// normalized
		
		lightint_coefficients,	
		light_direction,				// normalized
		light_intensity,
		
		albedo.xyz,					// diffuse_reflectance
		specular_mask,
		texcoord,
		prt_ravi_diff,
		tangent_frame,

		envmap_specular_reflectance_and_roughness,
		envmap_area_specular_only,
		specular_radiance,
		diffuse_radiance);
			
	//compute environment map
	envmap_area_specular_only= max(envmap_area_specular_only, 0.001f);
	float3 envmap_radiance= CALC_ENVMAP(envmap_type)(view_dir, bump_normal, view_reflect_dir, envmap_specular_reflectance_and_roughness, envmap_area_specular_only);

	//compute self illumination	
	float3 self_illum_radiance= calc_self_illumination_ps(texcoord, albedo.xyz, view_dir_in_tangent_space, fragment_position, fragment_to_camera_world, view_dot_normal) * ILLUM_SCALE;
	
	float4 out_color;
	
	// set color channels
#ifdef BLEND_MULTIPLICATIVE
	out_color.xyz= (albedo.xyz + self_illum_radiance);		// No lighting, no fog, no exposure
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= out_color.xyz * BLEND_MULTIPLICATIVE;
	out_color.w= ALPHA_CHANNEL_OUTPUT;
#elif defined(BLEND_FRESNEL)
	out_color.xyz= (diffuse_radiance 
#ifndef _PBR_FX_
					* albedo.xyz * albedo.w 
#endif
					+ self_illum_radiance + envmap_radiance + specular_radiance);
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= (out_color.xyz * extinction + inscatter * BLEND_FOG_INSCATTER_SCALE) * g_exposure.rrr;
	out_color.w= saturate(specular_radiance.w + albedo.w);
#else
	out_color.xyz= (diffuse_radiance 
#ifndef _PBR_FX_
					* albedo.xyz 
#endif
					+ specular_radiance + self_illum_radiance + envmap_radiance);
	APPLY_OVERLAYS(out_color.xyz, texcoord, view_dot_normal)
	out_color.xyz= (out_color.xyz * extinction + inscatter * BLEND_FOG_INSCATTER_SCALE) * g_exposure.rrr;
	out_color.w= ALPHA_CHANNEL_OUTPUT;
#endif
		
//	return float4(albedo.xyz, 0);	
	return out_color;
}

///constant to do order 2 SH convolution
#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_per_pixel_vs(
	in vertex_type vertex,
	in s_lightmap_per_pixel lightmap,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float4 lightmap_texcoord : TEXCOORD6,
	out float3 fragment_to_camera_world : TEXCOORD7,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1)
{

	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	lightmap_texcoord= float4(lightmap.texcoord, 0, 0);
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space direction to eye/camera
	fragment_to_camera_world= Camera_Position-vertex.position;

	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);
	
	CALC_CLIP(position);	
}

#include "lightmap_sampling.fx"

accum_pixel static_per_pixel_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD3,
	in float3 binormal : TEXCOORD4,
	in float3 tangent : TEXCOORD5,
	in float4 lightmap_texcoord : TEXCOORD6_centroid,
	in float3 fragment_to_camera_world : TEXCOORD7,
	in float3 extinction : COLOR0,
	in float3 inscatter : COLOR1
	) : SV_Target
{
	// normalize interpolated values
#ifndef ALPHA_OPTIMIZATION
	normal= normalize(normal);
	binormal= normalize(binormal);
	tangent= normalize(tangent);
#endif

	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};

	float3 sh_coefficients[4];

	float3 dominant_light_direction;
	float3 dominant_light_intensity;

	sample_lightprobe_texture(
		lightmap_texcoord.xy,
		sh_coefficients,
		dominant_light_direction,
		dominant_light_intensity);

	float4 prt_ravi_diff= float4(1.0f, 1.0f, 1.0f, dot(tangent_frame[2], dominant_light_direction));

	float4 sh_lighting_coefficients[4];	
	pack_constants_texture_array_linear(sh_coefficients, sh_lighting_coefficients);

	float4 out_color= calc_output_color_with_explicit_light_linear_with_dominant_light(
		fragment_position,
		tangent_frame,
		sh_lighting_coefficients,
		fragment_to_camera_world,
		texcoord,
		prt_ravi_diff,
		dominant_light_direction,
		dominant_light_intensity,
		extinction,
		inscatter);

	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);
	
}

///constant to do order 2 SH convolution
#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_sh_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float3 texcoord_and_vertexNdotL : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float3 fragment_to_camera_world : TEXCOORD6,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1)
{

	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord_and_vertexNdotL.xy= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;
	
	texcoord_and_vertexNdotL.z= dot(normal, get_constant_analytical_light_dir_vs());
		
	// world space direction to eye/camera
	fragment_to_camera_world.rgb= Camera_Position-vertex.position;
	
	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);
	
	CALC_CLIP(position);
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
accum_pixel static_sh_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float3 texcoord_and_vertexNdotL : TEXCOORD0,
	in float3 normal : TEXCOORD3,
	in float3 binormal : TEXCOORD4,
	in float3 tangent : TEXCOORD5,
	in float3 fragment_to_camera_world : TEXCOORD6,
	in float3 extinction : COLOR0,
	in float3 inscatter : COLOR1)
{
	// normalize interpolated values
#ifndef ALPHA_OPTIMIZATION
	normal= normalize(normal);
	binormal= normalize(binormal);
	tangent= normalize(tangent);
#endif
	
	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};

	// build sh_lighting_coefficients
	float4 sh_lighting_coefficients[10]=
		{
			p_lighting_constant_0, 
			p_lighting_constant_1, 
			p_lighting_constant_2, 
			p_lighting_constant_3, 
			p_lighting_constant_4, 
			p_lighting_constant_5, 
			p_lighting_constant_6, 
			p_lighting_constant_7, 
			p_lighting_constant_8, 
			p_lighting_constant_9 
		}; 	
	
	float4 prt_ravi_diff= float4(1.0f, 0.0f, 1.0f, dot(tangent_frame[2], k_ps_dominant_light_direction));
	float4 out_color= calc_output_color_with_explicit_light_quadratic(
		fragment_position,
		tangent_frame,
		sh_lighting_coefficients,
		fragment_to_camera_world,
		texcoord_and_vertexNdotL.xy,
		prt_ravi_diff,
		k_ps_dominant_light_direction,
		k_ps_dominant_light_intensity,
		extinction,
		inscatter);


	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);	
}

///constant to do order 2 SH convolution
#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_per_vertex_vs(
	in vertex_type vertex,
	in float4 light_intensity : TEXCOORD3,
	in float4 c0_3_rgbe : TEXCOORD4,
	in float4 c1_1_rgbe : TEXCOORD5,
	in float4 c1_2_rgbe : TEXCOORD6,
	in float4 c1_3_rgbe : TEXCOORD7,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float4 texcoord : TEXCOORD0,  // zw contains inscatter.xy
	out float3 fragment_to_camera_world : TEXCOORD1,
	out float3 tangent : TEXCOORD2,
	out float3 normal : TEXCOORD3,	
	out float3 binormal : TEXCOORD4,
	out float4 probe0_3_r : TEXCOORD5,
	out float4 probe0_3_g : TEXCOORD6,
	out float4 probe0_3_b : TEXCOORD7,
	out float3 dominant_light_intensity : TEXCOORD8,
	out float4 extinction : COLOR0) // w contains inscatter.z
//	out float3 inscatter : COLOR1)
{
#ifdef pc	
   // on PC vertex lightnap is stored in unsigned format
   // convert to signed
   light_intensity = 2 * light_intensity - 1;
	c0_3_rgbe = 2 * c0_3_rgbe - 1;
	c1_1_rgbe = 2 * c1_1_rgbe - 1;
	c1_2_rgbe = 2 * c1_2_rgbe - 1;
	c1_3_rgbe = 2 * c1_3_rgbe - 1;
#endif

//   float3 debug_out = c1_3_rgbe.xyz;

	// output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);

	normal= vertex.normal;
	texcoord.xy= vertex.texcoord;
	binormal= vertex.binormal;
	tangent= vertex.tangent;

	//const real exponent_mult= 127.f/pow(2.f, fractional_exponent_bits); == 31.75f
	
	float scale= exp2(light_intensity.a * 31.75f);
	light_intensity.rgb*= scale;
	
	scale= exp2(c0_3_rgbe.a * 31.75f);
	c0_3_rgbe.rgb*= scale;
	
	scale= exp2(c1_1_rgbe.a * 31.75f);
	c1_1_rgbe.rgb*= scale;

	scale= exp2(c1_2_rgbe.a * 31.75f);
	c1_2_rgbe.rgb*= scale;
	
	scale= exp2(c1_3_rgbe.a * 31.75f);
	c1_3_rgbe.rgb*= scale;
		
	probe0_3_r= float4(c0_3_rgbe.r, c1_1_rgbe.r, c1_2_rgbe.r, c1_3_rgbe.r);
	probe0_3_g= float4(c0_3_rgbe.g, c1_1_rgbe.g, c1_2_rgbe.g, c1_3_rgbe.g);
	probe0_3_b= float4(c0_3_rgbe.b, c1_1_rgbe.b, c1_2_rgbe.b, c1_3_rgbe.b);

	dominant_light_intensity= light_intensity.xyz;

	fragment_to_camera_world= Camera_Position-vertex.position;
	
	float3 inscatter;
	compute_scattering(Camera_Position, vertex.position, extinction.xyz, inscatter);
	texcoord.zw  = inscatter.xy;
	extinction.w = inscatter.z;
	
//	dominant_light_intensity= debug_out;

	CALC_CLIP(position);
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
accum_pixel static_per_vertex_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float4 texcoord : TEXCOORD0, // zw contains inscatter.xy
	in float3 fragment_to_camera_world : TEXCOORD1,
	in float3 tangent : TEXCOORD2,
	in float3 normal : TEXCOORD3,
	in float3 binormal : TEXCOORD4,
	in float4 p0_3_r : TEXCOORD5,
	in float4 p0_3_g : TEXCOORD6,
	in float4 p0_3_b : TEXCOORD7,
	in float3 dominant_light_intensity : TEXCOORD8,
	in float4 extinction : COLOR0) // w contains inscatter.z
//	in float3 inscatter : COLOR1)
{
//	float3 view_dir= normalize(fragment_to_camera_world);		// world space direction to eye/camera

	// normalize interpolated values
#ifndef ALPHA_OPTIMIZATION
	normal= normalize(normal);
	binormal= normalize(binormal);
//	float3 tangent= normalize(cross(binormal, normal));
	tangent= normalize(tangent);
#endif

	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};

	// build sh_lighting_coefficients
	float4 L0_3[3]= {p0_3_r, p0_3_g, p0_3_b};
	
	//compute dominant light dir
	float3 dominant_light_direction= p0_3_r.wyz * 0.212656f + p0_3_g.wyz * 0.715158f + p0_3_b.wyz * 0.0721856f;
	dominant_light_direction= dominant_light_direction * float3(-1.0f, -1.0f, 1.0f);
	dominant_light_direction= normalize(dominant_light_direction);
	
	float4 lighting_constants[4];
	pack_constants_linear(L0_3, lighting_constants);

	float4 prt_ravi_diff= float4(1.0f, 1.0f, 1.0f, dot(tangent_frame[2], dominant_light_direction));

	float4 out_color= calc_output_color_with_explicit_light_linear_with_dominant_light(
		fragment_position,
		tangent_frame,
		lighting_constants,
		fragment_to_camera_world,
		texcoord.xy,
		prt_ravi_diff,
		dominant_light_direction,
		dominant_light_intensity,
		extinction.xyz,
		float3(texcoord.z, texcoord.w, extinction.w));
		
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);	
}

//straight vert color
#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_per_vertex_color_vs(
	in vertex_type vertex,
	in float3 vert_color				: TEXCOORD3,
	out float4 position					: SV_Position,
	CLIP_OUTPUT
	out float2 texcoord					: TEXCOORD0,
	out float3 out_color				: TEXCOORD1,
	out float3 fragment_to_camera_world : TEXCOORD2,
	out float3 normal					: TEXCOORD3,
	out float3 binormal					: TEXCOORD4,
	out float3 tangent					: TEXCOORD5,
	out float3 extinction				: COLOR0,
	out float3 inscatter				: COLOR1)
{
	// output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	fragment_to_camera_world= Camera_Position-vertex.position;		// world space direction to eye/camera
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	binormal= vertex.binormal;
	tangent= vertex.tangent;
	out_color= vert_color;	
	
	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);
	
	CALC_CLIP(position);
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
accum_pixel static_per_vertex_color_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float2 texcoord					: TEXCOORD0,
	in float3 vert_color				: TEXCOORD1,
	in float3 fragment_to_camera_world	: TEXCOORD2,
	in float3 normal					: TEXCOORD3,
	in float3 binormal					: TEXCOORD4,
	in float3 tangent					: TEXCOORD5,
	in float3 extinction				: COLOR0,
	in float3 inscatter					: COLOR1)
{
	
	// normalize interpolated values
	normal= normalize(normal);

	// no parallax?

	float output_alpha;
	// do alpha test
	calc_alpha_test_ps(texcoord, output_alpha);
	
	// get diffuse albedo, specular mask and bump normal
	float4 albedo;	
#ifdef maybe_calc_albedo
	if (actually_calc_albedo)						// transparent objects must generate their own albedo + normal
	{
		calc_albedo_ps(texcoord, albedo, normal);
	}
	else		
#endif
	{
#if DX_VERSION == 11
		albedo = albedo_texture.Load(int3(fragment_position.xy, 0));
#else
#ifndef pc
		fragment_position.xy+= p_tiling_vpos_offset.xy;
#endif
		float2 screen_texcoord= (fragment_position.xy + float2(0.5f, 0.5f)) / texture_size.xy;
		albedo= sample2D(albedo_texture, screen_texcoord);
#endif
	}

	//compute self illumination	
	float3 self_illum_radiance= calc_self_illumination_ps(texcoord, albedo.xyz, float3(1.0f, 1.0f, 1.0f), fragment_position, fragment_to_camera_world, 1.0f) * ILLUM_SCALE;
	
	float3 simple_light_diffuse_light;
	float3 simple_light_specular_light;
	float3 fragment_position_world= Camera_Position_PS - fragment_to_camera_world;
	calc_simple_lights_analytical(
		fragment_position_world,
		normal,
		float3(1.0f, 0.0f, 0.0f),										// view reflection direction (not needed cuz we're doing diffuse only)
		1.0f,
		simple_light_diffuse_light,
		simple_light_specular_light);
	
	// set color channels
	float4 out_color;
#ifdef BLEND_MULTIPLICATIVE
	out_color.xyz= (vert_color * albedo.xyz + self_illum_radiance) * BLEND_MULTIPLICATIVE;		// No lighting, no fog, no exposure
#else
	out_color.xyz= ((vert_color + simple_light_diffuse_light) * albedo.xyz  + self_illum_radiance);
	out_color.xyz= (out_color.xyz * extinction + inscatter * BLEND_FOG_INSCATTER_SCALE) * g_exposure.rrr;
#endif
	//out_color.xyz= vert_color * g_exposure.rgb;
	out_color.w= ALPHA_CHANNEL_OUTPUT;
		
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);
	
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_prt_ambient_vs(
	in vertex_type vertex,
#ifdef pc
	in float prt_c0_c3 : BLENDWEIGHT1,
#else // xenon
	in float vertex_index : SV_VertexID,
#endif // xenon
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float3 fragment_to_camera_world : TEXCOORD6,
	out float4 prt_ravi_diff : TEXCOORD7,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1)
{
#ifdef pc
//	float prt_c0= PRT_C0_DEFAULT;
	float prt_c0= prt_c0_c3;
#else // xenon
	// fetch PRT data from compressed 
	float prt_c0;

	float prt_fetch_index= vertex_index * 0.25f;								// divide vertex index by 4
	float prt_fetch_fraction= frac(prt_fetch_index);							// grab fractional part of index (should be 0, 0.25, 0.5, or 0.75) 

	float4 prt_values, prt_component;
	float4 prt_component_match= float4(0.75f, 0.5f, 0.25f, 0.0f);				// bytes are 4-byte swapped (each dword is stored in reverse order)
	asm
	{
		vfetch	prt_values, prt_fetch_index, blendweight1						// grab four PRT samples
		seq		prt_component, prt_fetch_fraction.xxxx, prt_component_match		// set the component that matches to one		
	};
	prt_c0= dot(prt_component, prt_values);
#endif // xenon

	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space direction to eye/camera
	fragment_to_camera_world= Camera_Position-vertex.position;
	
	float ambient_occlusion= prt_c0;
	float lighting_c0= 	dot(v_lighting_constant_0.xyz, float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f));			// ###ctchou $PERF convert to monochrome before passing in!
	float ravi_mono= (0.886227f * lighting_c0)/3.1415926535f;
	float prt_mono= ambient_occlusion * lighting_c0;
		
	prt_mono= max(prt_mono, 0.01f);													// clamp prt term to be positive
	ravi_mono= max(ravi_mono, 0.01f);									// clamp ravi term to be larger than prt term by a little bit
	float prt_ravi_ratio= prt_mono /ravi_mono;
	prt_ravi_diff.x= prt_ravi_ratio;												// diffuse occlusion % (prt ravi ratio)
	prt_ravi_diff.y= prt_mono;														// unused
	prt_ravi_diff.z= (ambient_occlusion * 3.1415926535f)/0.886227f;					// specular occlusion % (ambient occlusion)
	prt_ravi_diff.w= min(dot(normal, get_constant_analytical_light_dir_vs()), prt_mono);		// specular (vertex N) dot L (kills backfacing specular)
	
	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);

	CALC_CLIP(position);
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_prt_linear_vs(
	in vertex_type vertex,
//#ifndef pc	
	in float4 prt_c0_c3 : BLENDWEIGHT1,
//#endif // !pc
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float3 fragment_to_camera_world : TEXCOORD6,
	out float4 prt_ravi_diff : TEXCOORD7,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1)
{
	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space direction to eye/camera
	fragment_to_camera_world= Camera_Position-vertex.position;
	
	// new monochrome PRT/RAVI ratio calculation
	
	
#ifdef pc	
   // on PC vertex linear PRT data is stored in unsigned format convert to signed
	prt_c0_c3 = 2 * prt_c0_c3 - 1;
#endif
	
	// convert to monochrome
//#ifdef pc
//	float4 prt_c0_c3_monochrome= float4(PRT_C0_DEFAULT, 0.0f, 0.0f, 0.0f);
//#else // xenon	
	float4 prt_c0_c3_monochrome= prt_c0_c3;
//#endif // xenon
	float4 SH_monochrome_3120;
	SH_monochrome_3120.xyz= (v_lighting_constant_1.xyz + v_lighting_constant_2.xyz + v_lighting_constant_3.xyz) / 3.0f;		// ###ctchou $PERF convert to monochrome before setting the constants yo
	SH_monochrome_3120.w= dot(v_lighting_constant_0.xyz, float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f));

	//rotate the first 4 coefficients	
	float4 SH_monochrome_local_0123;
	sh_inverse_rotate_0123_monochrome(
		local_to_world_transform,
		SH_monochrome_3120,
		SH_monochrome_local_0123);
		
	float prt_mono=		dot(SH_monochrome_local_0123, prt_c0_c3_monochrome);		
	float ravi_mono= ravi_order_2_monochromatic(normal, SH_monochrome_3120);
		
	prt_mono= max(prt_mono, 0.01f);													// clamp prt term to be positive
	ravi_mono= max(ravi_mono, 0.01f);									// clamp ravi term to be larger than prt term by a little bit
	float prt_ravi_ratio= prt_mono / ravi_mono;
	prt_ravi_diff.x= prt_ravi_ratio;												// diffuse occlusion % (prt ravi ratio)
	prt_ravi_diff.y= prt_mono;														// unused
	prt_ravi_diff.z= (prt_c0_c3_monochrome.x * 3.1415926535f)/0.886227f;			// specular occlusion % (ambient occlusion)
	prt_ravi_diff.w= min(dot(normal, get_constant_analytical_light_dir_vs()), prt_mono);		// specular (vertex N) dot L (kills backfacing specular)

	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);

	CALC_CLIP(position);
}

void prt_quadratic(
	in float3 prt_c0_c2,
	in float3 prt_c3_c5,
	in float3 prt_c6_c8,	
	in float3 normal,
	float4 local_to_world_transform[3],
	out float4 prt_ravi_diff)
{
	// convert first 4 coefficients to monochrome
	float4 prt_c0_c3_monochrome= float4(prt_c0_c2.xyz, prt_c3_c5.x);			//(prt_c0_c3_r + prt_c0_c3_g + prt_c0_c3_b) / 3.0f;
	float4 SH_monochrome_3120;
	SH_monochrome_3120.xyz= (v_lighting_constant_1.xyz + v_lighting_constant_2.xyz + v_lighting_constant_3.xyz) / 3.0f;			// ###ctchou $PERF convert to mono before passing in?
	SH_monochrome_3120.w= dot(v_lighting_constant_0.xyz, float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f));
	
	// rotate the first 4 coefficients
	float4 SH_monochrome_local_0123;
	sh_inverse_rotate_0123_monochrome(
		local_to_world_transform,
		SH_monochrome_3120,
		SH_monochrome_local_0123);

	float prt_mono=		dot(SH_monochrome_local_0123, prt_c0_c3_monochrome);

	// convert last 5 coefficients to monochrome
	float4 prt_c4_c7_monochrome= float4(prt_c3_c5.yz, prt_c6_c8.xy);						//(prt_c4_c7_r + prt_c4_c7_g + prt_c4_c7_b) / 3.0f;
	float prt_c8_monochrome= prt_c6_c8.z;													//dot(prt_c8, float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f));
	float4 SH_monochrome_457= (v_lighting_constant_4 + v_lighting_constant_5 + v_lighting_constant_6) / 3.0f;
	float4 SH_monochrome_8866= (v_lighting_constant_7 + v_lighting_constant_8 + v_lighting_constant_9) / 3.0f;

	// rotate last 5 coefficients
	float4 SH_monochrome_local_4567;
	float SH_monochrome_local_8;
	sh_inverse_rotate_45678_monochrome(
		local_to_world_transform,
		SH_monochrome_457,
		SH_monochrome_8866,
		SH_monochrome_local_4567,
		SH_monochrome_local_8);

	prt_mono	+=	dot(SH_monochrome_local_4567, prt_c4_c7_monochrome);
	prt_mono	+=	SH_monochrome_local_8 * prt_c8_monochrome;

	float ravi_mono= ravi_order_3_monochromatic(normal, SH_monochrome_3120, SH_monochrome_457, SH_monochrome_8866);
	
	prt_mono= max(prt_mono, 0.01f);													// clamp prt term to be positive
	ravi_mono= max(ravi_mono, 0.01f);									// clamp ravi term to be larger than prt term by a little bit
	float prt_ravi_ratio= prt_mono / ravi_mono;
	prt_ravi_diff.x= prt_ravi_ratio;												// diffuse occlusion % (prt ravi ratio)
	prt_ravi_diff.y= prt_mono;														// unused
	prt_ravi_diff.z= (prt_c0_c3_monochrome.x * 3.1415926535f)/0.886227f;			// specular occlusion % (ambient occlusion)
	prt_ravi_diff.w= min(dot(normal, get_constant_analytical_light_dir_vs()), prt_mono);		// specular (vertex N) dot L (kills backfacing specular)
}

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void static_prt_quadratic_vs(
	in vertex_type vertex,
//#ifndef pc	
	in float3 prt_c0_c2 : BLENDWEIGHT1,
	in float3 prt_c3_c5 : BLENDWEIGHT2,
	in float3 prt_c6_c8 : BLENDWEIGHT3,		
//#endif // !pc
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD3,
	out float3 binormal : TEXCOORD4,
	out float3 tangent : TEXCOORD5,
	out float3 fragment_to_camera_world : TEXCOORD6,
	out float4 prt_ravi_diff : TEXCOORD7,
	out float3 extinction : COLOR0,
	out float3 inscatter : COLOR1)
{

	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space direction to eye/camera
	fragment_to_camera_world= Camera_Position-vertex.position;
	
// #ifdef pc	
// 	prt_ravi_diff.x= 1.0f;														// diffuse occlusion % (prt ravi ratio)
// 	prt_ravi_diff.y= 1.0f;														// unused
// 	prt_ravi_diff.z= 1.0f;														// specular occlusion % (ambient occlusion)
// 	prt_ravi_diff.w= dot(normal, get_constant_analytical_light_dir_vs());				// specular (vertex N) dot L (kills backfacing specular)
// #else // xenon
	prt_quadratic(
		prt_c0_c2,
		prt_c3_c5,
		prt_c6_c8,
		normal,
		local_to_world_transform,
		prt_ravi_diff);
//#endif // xenon
		
	compute_scattering(Camera_Position, vertex.position, extinction, inscatter);

	CALC_CLIP(position);
}

accum_pixel static_prt_ps(
	SCREEN_POSITION_INPUT(fragment_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD3,
	in float3 binormal : TEXCOORD4,
	in float3 tangent : TEXCOORD5,
	in float3 fragment_to_camera_world : TEXCOORD6,
	in float4 prt_ravi_diff : TEXCOORD7,
	in float3 extinction : COLOR0,
	in float3 inscatter : COLOR1)
{
	// normalize interpolated values
#ifndef ALPHA_OPTIMIZATION
	normal= normalize(normal);
	binormal= normalize(binormal);
	tangent= normalize(tangent);
#endif
//	float3 view_dir= normalize(fragment_to_camera_world);			// world space direction to eye/camera
	
	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};

	// build sh_lighting_coefficients
	float4 sh_lighting_coefficients[10]=
		{
			p_lighting_constant_0, 
			p_lighting_constant_1, 
			p_lighting_constant_2, 
			p_lighting_constant_3, 
			p_lighting_constant_4, 
			p_lighting_constant_5, 
			p_lighting_constant_6, 
			p_lighting_constant_7, 
			p_lighting_constant_8, 
			p_lighting_constant_9 
		}; 
	
	float4 out_color= calc_output_color_with_explicit_light_quadratic(
		fragment_position,
		tangent_frame,
		sh_lighting_coefficients,
		fragment_to_camera_world,
		texcoord,
		prt_ravi_diff,
		k_ps_dominant_light_direction,
		k_ps_dominant_light_intensity,
		extinction,
		inscatter);
				
	return CONVERT_TO_RENDER_TARGET_FOR_BLEND(out_color, true, false);	
}


#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void default_dynamic_light_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
#if DX_VERSION == 11
	out s_dynamic_light_clip_distance clip_distance,
#endif
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float3 fragment_to_camera_world : TEXCOORD4,
	out float4 fragment_position_shadow : TEXCOORD5)		// homogenous coordinates of the fragment position in projective shadow space
{
	//output to pixel shader
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;

	// world space direction to eye/camera
	fragment_to_camera_world= Camera_Position-vertex.position;
	
	fragment_position_shadow= mul(float4(vertex.position, 1.0f), Shadow_Projection);

#if DX_VERSION == 11	
	clip_distance = calc_dynamic_light_clip_distance(position);
#endif
}

void dynamic_light_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
#if DX_VERSION == 11
	out s_dynamic_light_clip_distance clip_distance,
#endif
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float3 fragment_to_camera_world : TEXCOORD4,
	out float4 fragment_position_shadow : TEXCOORD5)		// homogenous coordinates of the fragment position in projective shadow space
{
	default_dynamic_light_vs(
		vertex, 
		position, 
#if DX_VERSION == 11
		clip_distance,
#endif		
		texcoord, 
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world, 
		fragment_position_shadow);
}

void dynamic_light_cine_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
#if DX_VERSION == 11
	out s_dynamic_light_clip_distance clip_distance,
#endif
	out float2 texcoord : TEXCOORD0,
	out float3 normal : TEXCOORD1,
	out float3 binormal : TEXCOORD2,
	out float3 tangent : TEXCOORD3,
	out float3 fragment_to_camera_world : TEXCOORD4,
	out float4 fragment_position_shadow : TEXCOORD5)		// homogenous coordinates of the fragment position in projective shadow space
{
	default_dynamic_light_vs(
		vertex, 
		position, 
#if DX_VERSION == 11
		clip_distance,
#endif		
		texcoord, 		
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world, 
		fragment_position_shadow);
}

accum_pixel default_dynamic_light_ps(
	SCREEN_POSITION_INPUT(fragment_position),
#if DX_VERSION == 11
	in s_dynamic_light_clip_distance clip_distance,
#endif
	in float2 original_texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float3 fragment_to_camera_world : TEXCOORD4,
	in float4 fragment_position_shadow : TEXCOORD5,			// homogenous coordinates of the fragment position in projective shadow space
	bool cinematic)					
{
	// normalize interpolated values
#ifndef ALPHA_OPTIMIZATION
	normal= normalize(normal);
	binormal= normalize(binormal);
	tangent= normalize(tangent);
#endif

	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};

	// convert view direction to tangent space
	float3 view_dir= normalize(fragment_to_camera_world);
	float3 view_dir_in_tangent_space= mul(tangent_frame, view_dir);
	
	// compute parallax
	float2 texcoord;
	calc_parallax_ps(original_texcoord, view_dir_in_tangent_space, texcoord);

	float output_alpha;
	// do alpha test
	calc_alpha_test_ps(texcoord, output_alpha);

	// calculate simple light falloff for expensive light
	float3 fragment_position_world= Camera_Position_PS - fragment_to_camera_world;
	float3 light_radiance;
	float3 fragment_to_light;
	float light_dist2;
	calculate_simple_light(
		0,
		fragment_position_world,
		light_radiance,
		fragment_to_light);			// return normalized direction to the light

	fragment_position_shadow.xyz /= fragment_position_shadow.w;							// projective transform on xy coordinates
	
	// apply light gel
	light_radiance *=  sample2D(dynamic_light_gel_texture, transform_texcoord(fragment_position_shadow.xy, p_dynamic_light_gel_xform));
	
	// clip if the pixel is too far
//	clip(light_radiance - 0.0000001f);				// ###ctchou $TODO $REVIEW turn this into a dynamic branch?

	// get diffuse albedo, specular mask and bump normal
	float3 bump_normal;
	float4 albedo;	
	get_albedo_and_normal(bump_normal, albedo, texcoord, tangent_frame, fragment_to_camera_world, fragment_position);

	// calculate view reflection direction (in world space of course)
	///  DESC: 18 7 2007   12:50 BUNGIE\yaohhu :
	///    We don't need to normalize view_reflect_dir, as long as bump_normal and view_dir have been normalized
	///    and hlsl reflect can do that directly
	///float3 view_reflect_dir= normalize( (dot(view_dir, bump_normal) * bump_normal - view_dir) * 2 + view_dir );
	float3 view_reflect_dir= -normalize(reflect(view_dir, bump_normal));

#ifdef _PBR_FX_
	float3 specular_fresnel_color;
	float3 specular_albedo_color;
	float power_or_roughness;
	float3 analytic_specular_radiance;
	
	float4 spatially_varying_material_parameters;

	CALC_MATERIAL_ANALYTIC_SPECULAR(material_type)(
		view_dir,
		bump_normal,
		view_reflect_dir,
		fragment_to_light,
		light_radiance,
		albedo.xyz,									// diffuse reflectance (ignored for cook-torrance)
		texcoord,
		1.0f,
		tangent_frame,
		spatially_varying_material_parameters,			// only when use_material_texture is defined
		specular_fresnel_color,							// fresnel(specular_albedo_color)
		specular_albedo_color,							// specular reflectance at normal incidence
		analytic_specular_radiance);

	float3 radiance = oren_nayar(
								view_dir,
								bump_normal,
								fragment_to_light,
								light_radiance,
								specular_fresnel_color,
								spatially_varying_material_parameters.y,
								albedo.xyz
								) * (1 - spatially_varying_material_parameters.z);
	radiance += analytic_specular_radiance;

#else
	// calculate diffuse lobe
	float3 analytic_diffuse_radiance= light_radiance * dot(fragment_to_light, bump_normal) * albedo.rgb;
	float3 radiance= analytic_diffuse_radiance * GET_MATERIAL_DIFFUSE_MULTIPLIER(material_type)();

	// compute a blended normal attenuation factor from the length squared of the normal vector
	// blended normal pixels are MSAA pixels that contained normal samples from two different polygons, therefore the lerped vector upon resolve does not have a length of 1.0
	float normal_lengthsq= dot(bump_normal.xyz, bump_normal.xyz);
#ifndef pc	
	float blended_normal_attenuate= pow(normal_lengthsq, 8);
#endif	

	// calculate specular lobe
	float specular_mask;
	calc_specular_mask_ps(texcoord, albedo.w, specular_mask);

	float3 specular_multiplier= GET_MATERIAL_ANALYTICAL_SPECULAR_MULTIPLIER(material_type)(specular_mask);
	
	if (dot(specular_multiplier, specular_multiplier) > 0.0001f)			// ###ctchou $PERF unproven 'performance' hack
	{
	float3 specular_fresnel_color;
	float3 specular_albedo_color;
	float power_or_roughness;
	float3 analytic_specular_radiance;
	
	float4 spatially_varying_material_parameters;

	CALC_MATERIAL_ANALYTIC_SPECULAR(material_type)(
		view_dir,
		bump_normal,
		view_reflect_dir,
		fragment_to_light,
		light_radiance,
		albedo,									// diffuse reflectance (ignored for cook-torrance)
		texcoord,
		1.0f,
		tangent_frame,
		spatially_varying_material_parameters,			// only when use_material_texture is defined
		specular_fresnel_color,							// fresnel(specular_albedo_color)
		specular_albedo_color,							// specular reflectance at normal incidence
		analytic_specular_radiance);					// return specular radiance from this light				<--- ONLY REQUIRED OUTPUT FOR DYNAMIC LIGHTS
	
		radiance += analytic_specular_radiance * specular_multiplier;
	}
#endif
	
#ifndef pc	
	radiance*= blended_normal_attenuate;
#endif	
	
	// calculate shadow
	float unshadowed_percentage= 1.0f;
	if (dynamic_light_shadowing)
	{
		if (dot(radiance, radiance) > 0.0f)									// ###ctchou $PERF unproven 'performance' hack
		{
			float cosine= dot(normal.xyz, p_lighting_constant_1.xyz);								// p_lighting_constant_1.xyz = normalized forward direction of light (along which depth values are measured)
	//		float cosine= dot(normal.xyz, Shadow_Projection_z.xyz);

			float slope= sqrt(1-cosine*cosine) / cosine;										// slope == tan(theta) == sin(theta)/cos(theta) == sqrt(1-cos^2(theta))/cos(theta)
	//		slope= min(slope, 4.0f) + 0.2f;														// don't let slope get too big (results in shadow errors - see master chief helmet), add a little bit of slope to account for curvature
																								// ###ctchou $REVIEW could make this (4.0) a shader parameter if you have trouble with the masterchief's helmet not shadowing properly	

	//		slope= slope / dot(p_lighting_constant_1.xyz, fragment_to_light.xyz);				// adjust slope to be slope for z-depth
																			
			float half_pixel_size= p_lighting_constant_1.w * fragment_position_shadow.w;		// the texture coordinate distance from the center of a pixel to the corner of the pixel - increases linearly with increasing depth
			float depth_bias= (slope + 0.2f) * half_pixel_size;

			depth_bias= 0.0f;
		
			if (cinematic)
			{
				unshadowed_percentage= sample_percentage_closer_PCF_5x5_block_predicated(fragment_position_shadow, depth_bias);
			}
			else
			{
				unshadowed_percentage= sample_percentage_closer_PCF_3x3_block(fragment_position_shadow, depth_bias);
			}
		}
	}

	float4 out_color;
	
	// set color channels
	out_color.xyz= (radiance) * g_exposure.rrr * unshadowed_percentage;

	// set alpha channel
	out_color.w= ALPHA_CHANNEL_OUTPUT;

	return convert_to_render_target(out_color, true, true);
}

accum_pixel dynamic_light_ps(
	SCREEN_POSITION_INPUT(fragment_position),
#if DX_VERSION == 11
	in s_dynamic_light_clip_distance clip_distance,
#endif
	in float2 original_texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float3 fragment_to_camera_world : TEXCOORD4,
	in float4 fragment_position_shadow : TEXCOORD5)			// homogenous coordinates of the fragment position in projective shadow space
{
	return default_dynamic_light_ps(
		fragment_position, 
#if DX_VERSION == 11
		clip_distance,
#endif
		original_texcoord, 
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world, 
		fragment_position_shadow, 
		false);
}

accum_pixel dynamic_light_cine_ps(
	SCREEN_POSITION_INPUT(fragment_position),
#if DX_VERSION == 11
	in s_dynamic_light_clip_distance clip_distance,
#endif
	in float2 original_texcoord : TEXCOORD0,
	in float3 normal : TEXCOORD1,
	in float3 binormal : TEXCOORD2,
	in float3 tangent : TEXCOORD3,
	in float3 fragment_to_camera_world : TEXCOORD4,
	in float4 fragment_position_shadow : TEXCOORD5)			// homogenous coordinates of the fragment position in projective shadow space
{
	return default_dynamic_light_ps(
		fragment_position, 
#if DX_VERSION == 11
		clip_distance,
#endif
		original_texcoord, 
		normal, 
		binormal, 
		tangent, 
		fragment_to_camera_world, 
		fragment_position_shadow, 
		true);
}


//===============================================================
// DEBUG

#ifdef xdk_2907
[noExpressionOptimizations] 
#endif
void lightmap_debug_mode_vs(
	in vertex_type vertex,
	in s_lightmap_per_pixel lightmap,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 lightmap_texcoord:TEXCOORD0,
	out float3 normal:TEXCOORD1,
	out float2 texcoord:TEXCOORD2,
	out float3 tangent:TEXCOORD3,
	out float3 binormal:TEXCOORD4,
	out float3 fragment_to_camera_world:TEXCOORD5)
{

	float4 local_to_world_transform[3];
	fragment_to_camera_world= Camera_Position-vertex.position;

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position);
	lightmap_texcoord= lightmap.texcoord;	
	normal= vertex.normal;
	texcoord= vertex.texcoord;
	tangent= vertex.tangent;
	binormal= vertex.binormal;
	
	CALC_CLIP(position);
}

accum_pixel lightmap_debug_mode_ps(
	SCREEN_POSITION_INPUT(screen_position),
	CLIP_INPUT
	in float2 lightmap_texcoord:TEXCOORD0,
	in float3 normal:TEXCOORD1,
	in float2 texcoord:TEXCOORD2,
	in float3 tangent:TEXCOORD3,
	in float3 binormal:TEXCOORD4,
	in float3 fragment_to_camera_world:TEXCOORD5) : SV_Target
{   	
	float4 out_color;
	
	// setup tangent frame
	float3x3 tangent_frame = {tangent, binormal, normal};
	float3 bump_normal;
	calc_bumpmap_ps(texcoord, fragment_to_camera_world, tangent_frame, bump_normal);

	float3 ambient_only= 0.0f;
	float3 linear_only= 0.0f;
	float3 quadratic= 0.0f;

	out_color= display_debug_modes(
		lightmap_texcoord,
		normal,
		texcoord,
		tangent,
		binormal,
		bump_normal,
		ambient_only,
		linear_only,
		quadratic);
		
	return convert_to_render_target(out_color, true, false);
	
}

#if DX_VERSION == 11

void stipple_vs(
	in vertex_type vertex,
	out float4 position : SV_Position,
	CLIP_OUTPUT
	out float2 texcoord : TEXCOORD0)
{
	float4 local_to_world_transform[3];

	//output to pixel shader
	always_local_to_view(vertex, local_to_world_transform, position, true);

	texcoord= vertex.texcoord;
	
	CALC_CLIP(position);
}

float4 stipple_ps(
	SCREEN_POSITION_INPUT(screen_position),
	CLIP_INPUT
	in float2 texcoord : TEXCOORD0) : SV_Target
{
	stipple_test(screen_position);
	
	float output_alpha;
	calc_alpha_test_ps(texcoord, output_alpha);	
	
	return 0;
}

#endif
