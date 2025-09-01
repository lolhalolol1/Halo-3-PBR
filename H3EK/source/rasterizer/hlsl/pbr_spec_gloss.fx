#ifndef _PBR_SPEC_GLOSS_FX_
#define _PBR_SPEC_GLOSS_FX_

/*
pbr.fx
Sat, March 15, 2025 1:36pm (oli :D)
*/


#define PI 3.14159265358979323846264338327950f
#define _epsilon 0.00001f
//*****************************************************************************
// Analytical Diffuse-Only for point light source only
//*****************************************************************************
PARAM(float4, 	mat_albedo_tint);
PARAM(bool, 	tag_colour_change);
PARAM(bool, 	chameleon);
PARAM(float, 	gloss_bias);
PARAM(float, 	gloss_scale);
PARAM(float4, 	metalness);
PARAM(float,  	metalness_a);
PARAM(float4, 	front_colour);
PARAM(float, 	front_power);
PARAM(float4, 	mid_colour);
PARAM(float, 	mid_power);
PARAM(float4, 	rim_colour);
PARAM(float, 	rim_power);
//PARAM(bool,		carpaint);
//PARAM(float, 	paint_gloss_bias);
//PARAM(float,	paint_gloss_scale);
//PARAM(float4,	paint_metalness);
//PARAM(bool, 	aniso);
//PARAM(float, 	shift);
//PARAM(float, 	intensity_1);
//PARAM(float, 	intensity_2);

PARAM(bool, 	use_mask_material);

PARAM(float4, 	mask_albedo_tint);
PARAM(bool, 	mask_chameleon);
PARAM(float, 	mask_gloss_bias);
PARAM(float, 	mask_gloss_scale);
PARAM(float4, 	mask_metalness);
PARAM(float,  	mask_metalness_a);
PARAM(float4, 	mask_front_colour);
PARAM(float,  	mask_front_power);
PARAM(float4, 	mask_mid_colour);
PARAM(float, 	mask_mid_power);
PARAM(float4, 	mask_rim_colour);
PARAM(float, 	mask_rim_power);
//PARAM(bool,		mask_carpaint);
//PARAM(float, 	mask_paint_gloss_bias);
//PARAM(float,	mask_paint_gloss_scale);
//PARAM(float4,	mask_paint_metalness);*/
//*****************************************************************************
// cook-torrance for area light source in SH space
//*****************************************************************************

float get_material_pbr_spec_gloss_specular_power(float power_or_roughness)
{
	return 1.0f;
}

float3 get_analytical_specular_multiplier_pbr_spec_gloss_ps(float specular_mask)
{
	return specular_coefficient;
}

float3 get_diffuse_multiplier_pbr_spec_gloss_ps()
{
	return diffuse_coefficient;
}

float3 color_screen (float3 a, float3 b){
    float3 white = float3(1.0,1.0,1.0);
    return (white - (white-a)*(white-b));
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

float3 FresnelSchlick(in float3 f0, in float3 f1, in float dot_prod)
{
	return f0 + (f1 - f0) * pow(1 - dot_prod, 5);
}

float3 FresnelSchlickRoughness(in float3 f0, in float rough, in float dot_prod)
{
	float gloss = 1 - rough;
	return f0 + (max(gloss, f0) - f0) * pow(1 - dot_prod, 5);
}

float GlossToSpecPower(float gloss)
{
   return exp2(gloss * 10 + 1);
}

float SpecNormK(float pwr)
{
   return (pwr + 2) / 8;
//   return (0.0397436f * pwr + 0.0856832f);
}

float HeidrichSeidelCalcSpec(float3 tang, float3 V, float3 L, float specPwr)
{
   float cVT = -dot(V, tang);
   float sVT = sqrt(1.0 - cVT * cVT);

   float cLT = dot(L, tang);
   float sLT = sqrt(1.0 - cLT * cLT);
   
   return pow(saturate(sVT * sLT + cVT * cLT), specPwr);
}

void calc_material_analytic_specular_pbr_spec_gloss_ps(
	in float3 view_dir,										// fragment to camera, in world space
	in float3 normal_dir,									// bumped fragment surface normal, in world space
	in float3 view_reflect_dir,								// view_dir reflected about surface normal, in world space
	in float3 light_dir,									// fragment to light, in world space
	in float3 light_irradiance,								// light intensity at fragment; i.e. light_color
	in float3 diffuse_albedo_color,							// diffuse reflectance (ignored for cook-torrance)
	in float2 texcoord,
	in float vert_n_dot_l,
	in float3 surface_normal,
	in float4 misc,
	out float4 material_parameters,							// only when use_material_texture is defined
	out float3 specular_fresnel_color,						// fresnel(specular_albedo_color)
	out float3 specular_albedo_color,						// specular reflectance at normal incidence
	out float3 analytic_specular_radiance)					// return specular radiance from this light				<--- ONLY REQUIRED OUTPUT FOR DYNAMIC LIGHTS
{
//=====================================================
//		SEPARATE OUT INTO DIFFEREENT MATERIAL MODELS
//=====================================================
	float specular_mask = misc.w;
	float3 surface_tangent = misc.xyz;
	material_parameters= saturate(sampleBiasGlobal2D(material_texture, transform_texcoord(texcoord, material_texture_xform)));
	if(tag_colour_change)
	{
	material_parameters.xyz = lerp(material_parameters.xyz, material_parameters.xyz * primary_change_color.xyz, specular_mask);
	}
	//Should probably make different material models for each of these conditions to avoid dumb if statements

	if(use_mask_material)
	{
		material_parameters.xyz = 	lerp(clamp(material_parameters.xyz * metalness.xyz + metalness.w, 0.0, 1.0),
										 clamp(material_parameters.xyz * mask_metalness.xyz + mask_metalness.w, 0.0, 1.0),
										 specular_mask);
		material_parameters.w = 	lerp(1 - clamp(material_parameters.w * gloss_scale + gloss_bias, 0.0, 0.999),
										 1 - clamp(material_parameters.w * mask_gloss_scale + mask_gloss_bias, 0.0, 0.999),
										 specular_mask);

	}
	else
	{
		material_parameters.xyz= clamp(material_parameters.xyz * metalness.xyz + metalness.w, 0.0, 1.0);
		material_parameters.w= 1 - clamp(material_parameters.w * gloss_scale + gloss_bias, 0.0, 0.999);
	}


	/*
	float final_spec_power = GlossToSpecPower(clamp(material_parameters.w * gloss_scale + gloss_bias, 0.0, 0.999));
	if(use_mask_material)
	{
		final_spec_power = lerp(final_spec_power, GlossToSpecPower(clamp(material_parameters.w * mask_gloss_scale + mask_gloss_bias, 0.0, 0.999)), specular_mask);
	}
	float spec_power_paint_1, spec_power_paint_2, final_spec_power_paint;

	if(carpaint || (mask_carpaint && use_mask_material))
	{
		spec_power_paint_1 = GlossToSpecPower(clamp(material_parameters.w * paint_gloss_scale + paint_gloss_bias, 0.0, 0.999));
		spec_power_paint_2 = GlossToSpecPower(clamp(material_parameters.w * mask_paint_gloss_scale + mask_paint_gloss_bias, 0.0, 0.999));

		final_spec_power_paint = 	(use_mask_material && mask_carpaint && carpaint) ? lerp(spec_power_paint_1, spec_power_paint_2, specular_mask) : 
									(carpaint && !use_mask_material) ? spec_power_paint_1 : spec_power_paint_2;
	}

    float3 H    = normalize(light_dir + view_dir);
    float NdotL = clamp(dot(normal_dir, light_dir), _epsilon, 1.0);
	//float NdotV = clamp((dot(normal_dir, view_dir)), _epsilon, 1.0);
    //float LdotH = clamp(dot(light_dir, H), _epsilon, 1.0);
	float VdotH = clamp(dot(view_dir, H), _epsilon, 1.0);
    float NdotH = clamp(dot(normal_dir, H), _epsilon, 1.0);
    //float min_dot = min(NdotL, NdotV);
	float ks, ks2;
if(aniso)
{
float3 Tang = normalize(surface_tangent + surface_normal * shift);
float3 Tang2 = normalize(Tang + shift * normal_dir);

float3 spec1 = HeidrichSeidelCalcSpec(Tang, view_dir, light_dir, final_spec_power);
float3 spec2 = HeidrichSeidelCalcSpec(Tang2, view_dir, light_dir, final_spec_power);
   
ks = 1 * (intensity_1 * spec1 + intensity_2 * spec2) * saturate(sign(dot(view_dir, surface_normal)));
	if(carpaint || (mask_carpaint && use_mask_material))
	{
		spec1 = HeidrichSeidelCalcSpec(Tang, view_dir, light_dir, final_spec_power_paint);
		spec2 = HeidrichSeidelCalcSpec(Tang2, view_dir, light_dir, final_spec_power_paint);

		ks2 = 1 * (intensity_1 * spec1 + intensity_2 * spec2) * saturate(sign(dot(view_dir, surface_normal)));
	}
}
else
{
	ks = pow(NdotH, final_spec_power);

	if(carpaint || (mask_carpaint && use_mask_material))
	{
		ks2 = pow(NdotH, final_spec_power_paint);
	}
}

	float3 f0 = clamp(material_parameters.xyz * metalness.xyz + metalness.w, 0.0, 1.0);
					
	if(use_mask_material)
	{
		f0 = lerp(f0, clamp(material_parameters.xyz * mask_metalness.xyz + mask_metalness.w, 0.0, 1.0), specular_mask);
	}

	specular_albedo_color = f0;


	float3 f0_paint_1, f0_paint_2, f0_paint_final;
	if(carpaint || (mask_carpaint && use_mask_material))
	{
		f0_paint_1 = clamp(material_parameters.xyz * paint_metalness.xyz + paint_metalness.w, 0.0, 1.0);
		f0_paint_2 = clamp(material_parameters.xyz * mask_paint_metalness.xyz + mask_paint_metalness.w, 0.0, 1.0);

		f0_paint_final = (use_mask_material && mask_carpaint && carpaint) ? lerp(f0_paint_1, f0_paint_2, specular_mask) : 
						 (carpaint && !use_mask_material) ? f0_paint_1 : f0_paint_2;
	}

	float3 F = FresnelSchlick(f0, 1, VdotH);
	specular_fresnel_color = F;

	analytic_specular_radiance = F * ks * NdotL * light_irradiance;

	if(carpaint || (mask_carpaint && use_mask_material))
	{
		ks *= SpecNormK(final_spec_power);
		ks2 *= SpecNormK(final_spec_power_paint);
		float3 F_paint = FresnelSchlick(f0_paint_final, 1, VdotH);
		analytic_specular_radiance *= ks;
		analytic_specular_radiance += F_paint * ks2 * NdotL * light_irradiance;
	}

	if(use_mask_material)
	{
	material_parameters.w = 	lerp(1 - clamp(material_parameters.w * gloss_scale + gloss_bias, 0.0, 0.999),
									1 - clamp(material_parameters.w * mask_gloss_scale + mask_gloss_bias, 0.0, 0.999),
									specular_mask);
	}
	else
	{
		material_parameters.w= 1 - clamp(material_parameters.w * gloss_scale + gloss_bias, 0.0, 0.999);
	}*/
    float3 H    = normalize(light_dir + view_dir);
    float NdotL = clamp(dot(normal_dir, light_dir), _epsilon, 1.0);
	float NdotV = clamp((dot(normal_dir, view_dir)), _epsilon, 1.0);
    float LdotH = clamp(dot(light_dir, H), _epsilon, 1.0);
	float VdotH = clamp(dot(view_dir, H), _epsilon, 1.0);
    float NdotH = clamp(dot(normal_dir, H), _epsilon, 1.0);

    float a2_sqrd   = pow(material_parameters.w, 4);

	float3 f0 = material_parameters.xyz;
	specular_albedo_color = f0;

	float3 F = FresnelSchlick(f0, 1, VdotH);
	specular_fresnel_color = F;

    //Normal Distribution Function
    float NDFdenom = max((NdotH * a2_sqrd - NdotH) * NdotH + 1.0, _epsilon);
    float NDF = a2_sqrd / (PI * NDFdenom * NDFdenom);

    //Geometry
    float L = 2.0 * NdotL / (NdotL + sqrt(a2_sqrd + (1.0 - a2_sqrd) * (NdotL * NdotL)));
	float V = 2.0 * NdotV / (NdotV + sqrt(a2_sqrd + (1.0 - a2_sqrd) * (NdotV * NdotV)));
    float G = L * V;

    //Final GGX
    float3 numerator    = NDF * 
                          G * 
                          F;
    float3 denominator  = max(4.0 * NdotV * NdotL, _epsilon);
	
    analytic_specular_radiance = (numerator / denominator) * light_irradiance * NdotL;

}

void calc_material_pbr_spec_gloss_ps(
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

		float3 albedo = diffuse_reflectance;
		calc_material_analytic_specular_pbr_spec_gloss_ps(
			view_dir,
			surface_normal,
			view_reflect_dir_world,
			analytical_light_dir,
			analytical_light_intensity,
			diffuse_reflectance,
			texcoord,
			prt_ravi_diff.w,
			tangent_frame[2],
			float4(tangent_frame[1],specular_mask),
			spatially_varying_material_parameters,
			fresnel_analytical,
			effective_reflectance,
			specular_analytical);

	
		float rough = spatially_varying_material_parameters.w;


	float3 area_specular;
	float3 NdotV = saturate(dot(surface_normal, view_dir));
	float3 f0 = effective_reflectance;
	float3 f1 = 1;
	float3 fRough;

	{
		fRough = FresnelSchlickRoughness(f0, rough, NdotV);
	}

	float3 simple_light_diffuse_light;
	float3 simple_light_specular_light;
	if (!no_dynamic_lights)
	{
		calc_simple_lights_spec_gloss(
				fragment_position_world,
				surface_normal,
				view_reflect_dir_world,							// view direction = fragment to camera,   reflected around fragment normal
				view_dir,
				f0,
				1,
				5,
				rough,
				diffuse_reflectance,
				simple_light_diffuse_light,						// diffusely reflected light (not including diffuse surface color)
				simple_light_specular_light);
	}
	else
	{
		simple_light_diffuse_light= 0.0f;
		simple_light_specular_light= 0.0f;
	}

	
	envmap_specular_reflectance_and_roughness= float4(EnvBRDFApprox(fRough, rough, NdotV) * diffuse_radiance, rough);
	envmap_area_specular_only = prt_ravi_diff.z * specular_coefficient;

	float metallic = max(max(f0.r, f0.g), f0.b);

	diffuse_radiance= (diffuse_radiance + simple_light_diffuse_light) * (1 - FresnelSchlickRoughness(metallic, rough, NdotV)) * (1 / PI) * prt_ravi_diff.x * diffuse_coefficient;
		
	specular_radiance.xyz= (simple_light_specular_light + specular_analytical) * prt_ravi_diff.z * specular_coefficient;//EnvBRDFApprox(fRough, rough, NdotV)
	
	specular_radiance.w= 0.0f;
}
	//Look into setting up the normal map here so you don't have Halo 3's weird Zbump bullshit.
#endif // _pbr_FX_
