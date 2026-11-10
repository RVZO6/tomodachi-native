# Zstandard decoder

`zstddeclib.c` is the decoder-only amalgamation of facebook/zstd **v1.5.7**,
generated with `build/single_file_libs/create_single_file_decoder.sh` from
<https://github.com/facebook/zstd/tree/v1.5.7>. It is used only to validate the
bounded face-paint frames in imported/exported Mii files. No encoder, CLI, game
content or keys are included. This copy uses the BSD license in `LICENSE`.
