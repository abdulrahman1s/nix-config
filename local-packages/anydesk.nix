{ anydesk, lib }:

anydesk.overrideAttrs (finalAttrs: previousAttrs: {
  # Growing the RPATH and replacing the interpreter in one patchelf call can
  # put .dynamic under an overlapping read-only LOAD segment, crashing ld.so.
  # Grow the RPATH first so the upstream fixup keeps .dynamic writable.
  postFixup = ''
    patchelf --set-rpath "${lib.makeLibraryPath finalAttrs.buildInputs}" "$out/bin/anydesk"
  '' + previousAttrs.postFixup;
})
