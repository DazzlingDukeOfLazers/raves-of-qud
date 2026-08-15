# Vendored: Voxel-Core (MIT)

Upstream: https://github.com/ClarkThyLord/Voxel-Core branch `4.0.0` @ eeff040e
(the Godot 4 port in progress; upstream master is Godot 3).

Local changes:

1. **Pruned 34 unported Godot-3 leftovers** the 4.0.0 branch still carried
   alongside its restructured port (old flat `classes/*.gd`, `controls/*`
   menus/viewers, `engine/importers/*`, and the old-structure
   `voxel_object_editor` selection/tool/cursor/grid files). None were
   referenced by the ported code; all failed to parse under Godot 4.7.
2. **Ported `classes/readers/vox.gd`** (the MagicaVoxel reader) to Godot 4
   ourselves: FileAccess/Transform3D/PackedInt32Array renames, plus a
   SEMANTIC fix — Godot 3's `continue` inside `match` fell through to `_`
   (which skipped an unhandled chunk's bytes); Godot 4's `continue` targets
   the enclosing loop and would desync any file with IMAP/LAYR/MATL/MATT/
   rOBJ chunks. Unhandled chunks now skip explicitly. Palette entries are
   plain Colors (the retired `Voxel` wrapper class is gone).

The game's band-driven wall volumes reach this plugin through
`tools/capture/wall2vox.py` (variant -> .vox); read the file back with
`VoxReader.read_file()` or open it in MagicaVoxel / vengi.
