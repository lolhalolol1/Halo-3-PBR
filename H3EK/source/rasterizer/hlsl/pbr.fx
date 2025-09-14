#ifndef _PBR_FX_
#define _PBR_FX_

/*
pbr.fx
Sat, March 15, 2025 1:36pm (oli :D)
*/
#define PI 3.14159265358979323846264338327950f
#define _epsilon 0.00001f

//*****************************************************************************
// Analytical Diffuse-Only for point light source only
//*****************************************************************************


PARAM(bool, convert_material);
PARAM(bool, ct_spec_rough);
PARAM(bool, use_specular_tints);
PARAM(float, roughness_bias);
PARAM(float, roughness_multiplier);
PARAM(float, metallic_bias);
PARAM(float, metallic_multiplier);
PARAM(float, fresnel_curve_steepness);

PARAM(float3, normal_specular);			//reflectance at normal incidence
PARAM(float3, glancing_specular);
PARAM(float,  albedo_blend);
PARAM(float,  cubemap_or_area_specular);

PARAM(bool, 	chameleon);
PARAM(float4, 	front_colour);
PARAM(float, 	front_power);
PARAM(float4, 	mid_colour);
PARAM(float, 	mid_power);
PARAM(float4, 	rim_colour);
PARAM(float, 	rim_power);

//*****************************************************************************
// cook-torrance for area light source in SH space
//*****************************************************************************
float3 color_screen (float3 a, float3 b){
    float3 white = float3(1.0,1.0,1.0);
    return (white - (white-a)*(white-b));
}

float get_material_pbr_specular_power(float power_or_roughness)
{
	return 1.0f;
}

float3 get_analytical_specular_multiplier_pbr_ps(float specular_mask)
{
	return 0.0f;
}

float3 get_diffuse_multiplier_pbr_ps()
{
	return 1.0f;
}

float3 EnvBRDFApprox(in float3 SpecularColor, in float Roughness, in float NoV )
{
	const float4 c0 = { -1, -0.0275, -0.572, 0.022 };
	const float4 c1 = { 1, 0.0425, 1.04, -0.04 };
	float4 r = Roughness * c0 + c1;
	float a004 = min( r.x * r.x, exp2( -9.28 * NoV ) ) * r.x + r.y;
	float2 AB = float2( -1.04, 1.04 ) * a004 + r.zw;
	return SpecularColor * AB.x + AB.y;
}

float3 oren_nayar(
	in float3 view_dir,
	in float3 view_normal,
	in float3 view_light_dir,
	in float3 light_color,
	in float3 fresnel,
	in float  rough,
	in float3 albedo
)
{
    float NoL = max(dot(view_normal, view_light_dir), 0.0); 
	float NoV = max(dot(view_normal, view_dir), _epsilon);
	float LoV = max(dot(view_light_dir, view_dir), 0.0);

	float ON_a2 = rough * rough;
	float s = LoV - NoL * NoV;
	float t = lerp(1.0, max(NoL, NoV), step(0.0, s));
	float3 A		= 1 + ON_a2 * (-0.5 / (ON_a2 + 0.33) + 0.17 * albedo / (ON_a2 + 0.13));
	float B 	= 	  0.45 * ON_a2 / (ON_a2 + 0.09);
	float3 ONdif =  albedo * (1 - fresnel) * (A + B * s / t) * (1 / PI) * light_color * NoL;

	return ONdif;
}

void chameleon_pbr(
	in float3 view_dir,
	in float3 bump_normal,
	in float chameleon_mask,
	inout float3 albedo)
{
	float3 temp_albedo;
	float view_dot_normal = clamp(dot(bump_normal, view_dir), 0.0001, 1);
	float fresnel  = 1 - clamp(view_dot_normal, 0.0001, 1);

	float3 fresnel_color = 0;
		
	float3  rim_fresnel = pow(fresnel, rim_power * 5);
	float3  mid_fresnel = pow(fresnel, mid_power * 5);
	float3  frt_fresnel = pow(1-fresnel, front_power * 5);
	

	mid_fresnel *= 1-rim_fresnel;
	frt_fresnel *= 1-mid_fresnel;

	rim_fresnel *= rim_colour;
	mid_fresnel *= mid_colour;
	frt_fresnel *= front_colour;

	fresnel_color = color_screen(rim_fresnel, mid_fresnel);
	fresnel_color = color_screen(fresnel_color, frt_fresnel);

	albedo.xyz = lerp(albedo.xyz, albedo.xyz * fresnel_color, chameleon_mask);
}

float3 oren_nayar_and_sh(
	in float3 view_dir,
	in float3 view_normal,
	in float3 view_light_dir,
	in float3 light_color,
	in float rough,
	in float4 sh_lighting_coefficients[10],
	in float3 albedo,
	in float3x3 tangent_frame,
	in float3 fresnel)
{
	float3 ONdif = oren_nayar(view_dir, view_normal, view_light_dir, light_color, fresnel, rough, albedo);
	//Crackhead attempt at redoing spherical harmonics
	float3 dir_eval= float3(-0.4886025f * view_light_dir.y, -0.4886025f * view_light_dir.z, -0.4886025 * view_light_dir.x);
	float4 lighting_constants[4] = {
		sh_lighting_coefficients[0],
		sh_lighting_coefficients[1],
		sh_lighting_coefficients[2],
		sh_lighting_coefficients[3]};

	lighting_constants[1].xyz -= dir_eval.zxy * light_color.x;//Replace constants with "sh_lighting_coefficients" if tool throws a fit.
	lighting_constants[2].xyz -= dir_eval.zxy * light_color.y;
	lighting_constants[3].xyz -= dir_eval.zxy * light_color.z;
	lighting_constants[0].xyz -= 0.2820948f * light_color;
	
	float3 x1;	
	x1.r = dot( view_normal, lighting_constants[1].rgb);		// linear red
	x1.g = dot( view_normal, lighting_constants[2].rgb);		// linear green
	x1.b = dot( view_normal, lighting_constants[3].rgb);		// linear blue
	float c1 = 0.429043f;
	float c2 = 0.511664f;
	float c4 = 0.886227f;
	float3 lightprobe_color = (c4 * lighting_constants[0].rgb + (-2.f * c2) * x1) / PI;
	return ONdif + lightprobe_color * albedo;
}

void calc_material_analytic_specular_pbr_ps(
	in float3 view_dir,										// fragment to camera, in world space
	in float3 normal_dir,									// bumped fragment surface normal, in world space
	in float3 view_reflect_dir,								// view_dir reflected about surface normal, in world space
	in float3 light_dir,									// fragment to light, in world space
	in float3 light_irradiance,								// light intensity at fragment; i.e. light_color
	inout float3 diffuse_albedo_color,							// diffuse reflectance (ignored for cook-torrance)
	in float2 texcoord,
	in float vert_n_dot_l,
	in float3 surface_normal,
	in float4 misc,
	out float4 material_parameters,							// only when use_material_texture is defined
	out float3 specular_fresnel_color,						// fresnel(specular_albedo_color)
	out float3 specular_albedo_color,						// specular reflectance at normal incidence
	out float3 analytic_specular_radiance)					// return specular radiance from this light				<--- ONLY REQUIRED OUTPUT FOR DYNAMIC LIGHTS
{
	material_parameters= saturate(sampleBiasGlobal2D(material_texture, transform_texcoord(texcoord, material_texture_xform)));

	//Should probably make different material models for each of these conditions to avoid dumb if statements
	if(!convert_material && !ct_spec_rough)
	{
		material_parameters.y= clamp(material_parameters.y * roughness_multiplier + roughness_bias, 0.005, 1.0);
		material_parameters.z= saturate(material_parameters.z * metallic_multiplier + metallic_bias);
	}
	else
	{
		if(ct_spec_rough)
		{
			material_parameters.xyz = float3(1, 
											 clamp(material_parameters.y * roughness_multiplier + roughness_bias, 0.005, 1.0), 
											 saturate(material_parameters.x * metallic_multiplier + metallic_bias));
		}
		else
		{
			material_parameters.x = 1;
			material_parameters.y = clamp((1 - misc.x) * roughness_multiplier + roughness_bias, 0.005, 1.0);
			material_parameters.z = metallic_bias;
		}
	}
	if(chameleon)
	{
		chameleon_pbr(view_dir, normal_dir, material_parameters.w, diffuse_albedo_color);
	}
    float3 H    = normalize(light_dir + view_dir);
    float NdotL = clamp(dot(normal_dir, light_dir), 0.0001, 1.0);
	float NdotV = clamp(abs(dot(normal_dir, view_dir)), 0.0001, 1.0);
    float LdotH = clamp(dot(light_dir, H), 0.0001, 1.0);
	float VdotH = clamp(dot(view_dir, H), 0.0001, 1.0);
    float NdotH = clamp(dot(normal_dir, H), 0.0001, 1.0);
    float min_dot = min(NdotL, NdotV);

    float a2_sqrd   = pow(material_parameters.y, 4);

	float3 F;
	float3 f0 = use_specular_tints ? lerp(normal_specular, diffuse_albedo_color, albedo_blend) : lerp(float3(0.04, 0.04, 0.04), diffuse_albedo_color, material_parameters.z);
	specular_albedo_color = f0;
	float3 f1;
	if(chameleon)
	{
		f1 = use_specular_tints ? lerp(1, glancing_specular, misc.x) : 1;
	}
	else
	{
		f1 = use_specular_tints ? glancing_specular : 1;
	}

	float fresnel_blend;
	if(use_specular_tints)
	{
		specular_albedo_color = lerp(normal_specular, diffuse_albedo_color, albedo_blend);
		fresnel_blend = pow(1.0f - VdotH, fresnel_curve_steepness);
	}
	else
	{
		specular_albedo_color = lerp(float3(0.04,0.04,0.04), diffuse_albedo_color, material_parameters.b);
		fresnel_blend = pow(1.0f - VdotH, 5);
	}
	F = f0 + (f1 - f0) * fresnel_blend;
	specular_fresnel_color = F;

    //Normal Distribution Function
    float NDFdenom = max((NdotH * a2_sqrd - NdotH) * NdotH + 1.0, 0.0001);
    float NDF = a2_sqrd / (PI * NDFdenom * NDFdenom);

    //Geometry
    float L = 2.0 * NdotL / (NdotL + sqrt(a2_sqrd + (1.0 - a2_sqrd) * (NdotL * NdotL)));
	float V = 2.0 * NdotV / (NdotV + sqrt(a2_sqrd + (1.0 - a2_sqrd) * (NdotV * NdotV)));
    float G = L * V;

    //Final GGX
    float3 numerator    = NDF * 
                          G * 
                          F;
    float3 denominator  = max(4.0 * NdotV * NdotL, 0.0001);
	
    analytic_specular_radiance = (NdotV != 0.0f) ? (numerator / denominator) * light_irradiance * NdotL : 0.00001f;
}

PARAM(float, roughness);
PARAM(float3, specular_tint);

float specular_power_from_roughness()
{
#if DX_VERSION == 11
	if (roughness == 0)
	{
		return 0;
	}
#endif	

	return 0.27291 * pow(roughness, -2.1973);
}

void calc_material_pbr_ps(
	in float3 view_dir,
	in float3 fragment_to_camera_world,
	in float3 surface_normal,
	in float3 view_reflect_dir_world,
	in float4 sh_lighting_coefficients[10],
	in float3 analytical_light_dir,
	in float3 analytical_light_intensity,
	in float3 diffuse_reflectance,
	in float  specular_mask,
	in float2 texcoord,
	in float4 prt_ravi_diff,
	in float3x3 tangent_frame, // = {tangent, binormal, normal};
	in float4 misc,
	out float4 envmap_specular_reflectance_and_roughness,
	out float3 envmap_area_specular_only,
	out float4 specular_radiance,
	inout float3 diffuse_radiance)
{
	float3 fragment_position_world= Camera_Position_PS - fragment_to_camera_world;
	
	float3 fresnel_analytical;			// fresnel_specular_albedo
	float3 effective_reflectance;		// specular_albedo (no fresnel)
	float4 per_pixel_parameters;
	float3 specular_analytical;			// specular radiance
	float4 spatially_varying_material_parameters;
		
	calc_material_analytic_specular_pbr_ps(
		view_dir,
		surface_normal,
		view_reflect_dir_world,
		analytical_light_dir,
		analytical_light_intensity,
		diffuse_reflectance,
		texcoord,
		prt_ravi_diff.w,
		tangent_frame[2],
		float4(specular_mask,0,0,0),
		spatially_varying_material_parameters,
		fresnel_analytical,
		effective_reflectance,
		specular_analytical);

	
	float rough = spatially_varying_material_parameters.y;
	float metallic = spatially_varying_material_parameters.z;


	float3 area_specular;
	float3 NdotV = saturate(dot(surface_normal, view_dir));
	float gloss = 1 - rough;
	float3 f0 = effective_reflectance;
	float3 f1;
	if(chameleon)
	{
		f1 = use_specular_tints ? lerp(max(gloss, f0), max(gloss, glancing_specular), specular_mask) : max(gloss, f0);
	}else
	{
		f1 = use_specular_tints ? glancing_specular : max(gloss, f0);
	}

	float fresnel_power = use_specular_tints ? fresnel_curve_steepness : 5;
	float3 fRough = f0 + (f1 - f0) * pow(1.0 - NdotV, fresnel_power);

	f1 = use_specular_tints ? glancing_specular : 1;
	float3 simple_light_diffuse_light;
	float3 simple_light_specular_light;
	if (!no_dynamic_lights)
	{
		calc_simple_lights_ggx(
				fragment_position_world,
				surface_normal,
				view_reflect_dir_world,							// view direction = fragment to camera,   reflected around fragment normal
				view_dir,
				effective_reflectance,
				f1,
				fresnel_power,
				rough,
				metallic,
				diffuse_reflectance,
				simple_light_diffuse_light,						// diffusely reflected light (not including diffuse surface color)
				simple_light_specular_light);
	}
	else
	{
		simple_light_diffuse_light= 0.0f;
		simple_light_specular_light= 0.0f;
	}

	
	envmap_specular_reflectance_and_roughness= float4(EnvBRDFApprox(fRough, rough, NdotV) * (diffuse_radiance), rough);
	envmap_area_specular_only = prt_ravi_diff.z * spatially_varying_material_parameters.x;

	diffuse_radiance = oren_nayar_and_sh(
							view_dir,
							surface_normal,
							analytical_light_dir,
							analytical_light_intensity,
							rough,
							sh_lighting_coefficients,
							diffuse_reflectance,
							tangent_frame,
							fresnel_analytical);

	//float ao_vert = 1 - ((1 - spatially_varying_material_parameters.x) * (1 - prt_ravi_diff.x));
	diffuse_radiance= (diffuse_radiance * (1 - metallic) + simple_light_diffuse_light) * prt_ravi_diff.x;
		
	specular_radiance.xyz= (simple_light_specular_light + specular_analytical) * prt_ravi_diff.z;//EnvBRDFApprox(fRough, rough, NdotV)
	
	specular_radiance.w= 0.0f;
	//diffuse_radiance = 0.0f;

	//diffuse_radiance = diffuse_reflectance;
	//specular_radiance.xyz = 0.00001f;
	//envmap_specular_reflectance_and_roughness= 0.0f;
}
	//Look into setting up the normal map here so you don't have Halo 3's weird Zbump bullshit.
#endif // _pbr_FX_
