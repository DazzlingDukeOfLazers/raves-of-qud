#!/usr/bin/env bash
# Type-check mod/*.cs against Qud's SHIPPED assemblies, without starting the game.
#
# WHY: Qud compiles mods at STARTUP. A single type error doesn't fail loudly at the edit --
# it silently drops the whole RavesOfQudBridge mod, so the bridge never listens and Raves
# just sits there disconnected. Finding that out costs a full Qud restart (~40s) plus the
# time spent misdiagnosing it as a bridge/network problem. This closes that loop to ~5s.
#
# It compiles to a throwaway DLL purely for the diagnostics; the artifact is discarded.
# Qud itself still does the real compile at load -- this is a fast pre-flight, not a build.
#
# Usage:  tools/check_mod.sh        -> prints errors, exit 1 on failure
set -uo pipefail
cd "$(dirname "$0")/.."

MANAGED="$HOME/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app/Contents/Resources/Data/Managed"
[ -d "$MANAGED" ] || { echo "STOP: Qud's Managed dir not found at $MANAGED"; exit 2; }

DOTNET_DIR=$(ls -d /opt/homebrew/Cellar/dotnet/* 2>/dev/null | head -1)
[ -n "$DOTNET_DIR" ] || { echo "STOP: no dotnet in /opt/homebrew/Cellar"; exit 2; }
export DOTNET_ROOT="$DOTNET_DIR/libexec"
export PATH="$DOTNET_ROOT:$PATH"

OUT="${TMPDIR:-/tmp}/raves-modcheck"
rm -rf "$OUT"; mkdir -p "$OUT"

# Reference every shipped assembly: the mod touches Assembly-CSharp, the Unity modules and
# the BCL facades, and enumerating them by hand goes stale the next time Qud updates.
# ...EXCEPT the BCL facades Unity ships (netstandard/mscorlib/System.*). Those forward types
# straight back to themselves under the netstandard2.1 SDK, and the compiler reports the cycle
# as "Predefined type 'System.String' is not defined" on every single line of the mod. Let the
# SDK's own reference pack supply the BCL and reference only the GAME's assemblies.
REFS=()
for dll in "$MANAGED"/*.dll; do
  base=$(basename "$dll" .dll)
  case "$base" in
    netstandard|mscorlib|System|System.*|Microsoft.CSharp|Mono.*) continue ;;
  esac
  REFS+=("<Reference Include=\"$base\"><HintPath>$dll</HintPath></Reference>")
done

cat > "$OUT/check.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>netstandard2.1</TargetFramework>
    <AssemblyName>RavesModCheck</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <!-- Qud's compiler is permissive about these; matching it keeps the check honest
         rather than failing on warnings the game would happily load. -->
    <NoWarn>CS0436;CS1701;CS1702;CS0618;CS0219;CS0168;CS0162;NU1701</NoWarn>
    <LangVersion>latest</LangVersion>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <DisableImplicitNamespaceImports>true</DisableImplicitNamespaceImports>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
    <ProduceReferenceAssembly>false</ProduceReferenceAssembly>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$PWD/mod/*.cs" />
  </ItemGroup>
  <ItemGroup>
$(printf '    %s\n' "${REFS[@]}")
  </ItemGroup>
</Project>
EOF

LOG="$OUT/build.log"
dotnet build "$OUT/check.csproj" -v q --nologo -o "$OUT/bin" > "$LOG" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  echo "mod check OK ($(ls mod/*.cs | wc -l | tr -d ' ') files)"
else
  echo "MOD CHECK FAILED:"
  grep -E "error CS" "$LOG" | sed 's|^.*/mod/|mod/|' | sort -u | head -40
  [ -s "$LOG" ] || cat "$LOG"
fi
exit $rc
