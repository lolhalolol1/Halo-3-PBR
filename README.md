# Halo 3 PBR
A PBR material shader for Halo 3 and, once I get around to it, Halo 3: ODST.
This is meant to be used with environment mapping set to per-pixel for now, with cubemaps at a resolution of at least 128 per face.

A PBR terrain shader will come at some point.

## How to install:
Drag and drop the files inside this repo's "H3EK" folder into your editing kit's root directory.

## How to use:
Firstly make sure you have a texture set up in the following way:
- AO map on the red channel
- Roughness map on the green channel
- Metallic map on the blue channel
Make sure this texture is imported with the bitmap curve as "linear" and source gamma as 1. If you don't know how to do that,
just set the "Usage" option at the top of the bitmap tag to "Blend Map (linear for terrain)" and reimport it. Should work fine.

Then simply set the "material_model" option in your shader tag to "pbr" and put the aforementioned texture in the
"material_texture" field.

If the shader looks weird or broken on use, recompile your shader using the "compile-shader" command in tool;
```
                tool compile-shader "path\to\your\shader\tag" "win
```
If it still looks wrong, message me on Discord about it.

## Environment Mapping and Cubemaps
### IMPORTANT:
As of right now this is intended to only be used with the "per-pixel" environment mapping option, as dynamic cubemaps are not
generated with enough mips to represent rough, blurry reflections properly. Cubemaps used should also be of a high enough 
resolution to have a sufficient amount of mips. 128 per face is what I'd call the minimum resolution. 

I've included a "dynamic_expensive" option made by @EnashMods that will use dynamic cubemaps and blur/convolute them in real time, but this is
only there for testing purposes really.
***Do not use this option*** if you use a mid-range/budget GPU as it is very expensive to run, and I strongly recommend you don't use this in any publically released mods. If you do use it, cap your framerate.

## Options
There are several options to help you customize or tweak your materials Guerilla.

+  order3_area_specular
   - This swaps between order 2 and order 3 spherical harmonics. If that means
     nothing to you, don't worry; I have no clue how this works either.

     Off is for slightly lower quality specular indirect lighting,
     On is for slightly higher quality specular indirect lighting.
     You will not be able to tell the difference.
+  no_dynamic_lights
   - Self-explanatory.
+  material_texture
   - Self-explanatory.
+  use_specular_tints
   - Enables the use of specular tints that are modulated between based on
     the angle the surface is viewed at. This is for making iridescent
     materials, like unique visors or Covenant metals.
     The following options are related to this specifically:

     - normal_specular
       - Colour seen when viewing this material dead-on.
      
     - glancing_specular
       - Colour seen when viewing this material at glancing angles.
      
     - fresnel_curve_steepness
       - Controls the angle at which the specular colour will change.
      
     - albedo_blend
       - Determines whether to use normal_specular or the albedo map's colour for
         the specular colour seen when viewing this material dead-on.
         0 means it'll only use normal_specular.
         1 means it'll only use the albedo map.

+  cubemap_or_area_specular
   - Determines how much the cubemap is used. Higher means more cubemap.
     Preferably set this as 1 at all times. This was mainly added
     as a testing option.
         
+  convert_material
   - If you want to roughly convert a traditional Halo 3 material to
     use this shader without making a custom material map.
     It'll use the specular map in place of roughness by
     inverting it, and metalness will be derived from the
     metallic_bias option below.

+  roughness_bias
   - A minimum value for roughness. Any roughness from the
     material texture/converted specular will have this added to it, and anything
     with a roughness above 1 will be clamped to 1.

+  roughness_multiplier
   - Roughness is multiplied by this, **before roughness_bias is added.**
     Combine this with roughness_bias to tweak a material's roughness
     to fit within a certain range. Especially useful if you're using
     convert_material.

+  metallic_bias
   - Like roughness_bias but for metalness.
     If you're using convert_material, use this to set metalness.

+  metallic_multiplier
   - Like roughness_multiplier but for metalness.
