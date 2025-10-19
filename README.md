# Halo 3 PBR
A PBR material shader for Halo 3 and, once I get around to it, Halo 3: ODST.

I've also included a fix for dynamic shadows not being cast on decorators correctly, which is in a separate folder
for those who want just that without the PBR shaders. 
(Credit to whoever on the Eldewrito team found the fix for this, and to MtnDewIt for finding it and informing me of it)

Updates to the documentation to come, assuming I get around to it.
If anything here is out-of-date, unclear, or doesn't solve an issue you're having, DM me on Discord.


## How to install:
Drag and drop the files inside this repo's "H3EK" folder into your editing kit's root directory.

## How to use PBR
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
For dynamic reflections to work properly with PBR, you will need each of your level's cubemaps to be generated at the highest 
possible resolution (256) after using Pedro13's guide on editing tool to allow for full mipmap chains on cubemaps (found in the
"resources" tab in the Halo Mods Discord server).
Doing so will affect dynamic cubemap reflections on vanilla materials and there's no real catch-all fix I can implement for that,
but a rough fix would be to turn up the roughness multiplier in under environment_mapping in the tag.

You can also use static cubemaps, but you need to make sure it is of a high-enough resolution and has a decent amount of mips. Results
likely won't be 100% correct either as I'm pretty sure manually imported cubemaps don't get their mips blurred the way dynamic ones do.

I've included a "dynamic_expensive" option made by @EnashMods that will use dynamic cubemaps and blur/convolute them in real time instead
of relying on the mips of a higher-resolution cubemap, but results will be inconsistent due to the varying resolutions of vanilla cubemaps
and performance will be significantly impacted.
***Do not use this option*** if you use a mid-range/budget GPU, and I strongly recommend you don't use this in any publicly released mods. 
If you do use it, cap your framerate unless you want to cook a steak on your GPU.

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

## Fix for shadows on decorators
Installing this should be as simple as throwing the folders inside "decorator shadow fix\H3EK" into your own toolset and letting it replace files with the same name.

If you wanna know why it was broken in MCC, basically some parts of the game's shader code will have checks for if it's being compiled for PC or Xbox, or if it's for 
DX9 or DX11, for the sake of using different code that'll work on those platforms. The code for decorators has one of these checks which, on PC, has it pass through
a normal direction (direction the decorator's surface is facing towards) to the game engine. Meanwhile, the code for Xbox 360 doesn't pass in a normal direction at all
and it ends up getting defaulted to a normal direction facing upwards (0,0,1). Technically passing through the actual normal direction should be fine or outright better 
but it plays into visual flaws with how Halo 3's dynamic shadows are set up, where they get weaker based on the shadowed surface's direction relative to the shadow's 
direction. Just setting the normals to a direction facing up isn't correct, but sidesteps the shadow issue for the most part.

Luckily this means the fix is literally one short line of code and changing a single word on the line after. Thanks to MtnDewIt for pointing out that a fix existed in Eldewrito
and finding it, and obviously thanks to Pedro13 for making the original fix in Eldewrito.
