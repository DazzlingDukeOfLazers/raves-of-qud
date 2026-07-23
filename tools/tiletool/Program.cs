using AssetsTools.NET;
using AssetsTools.NET.Extra;

// Stage 1: inspector. Answers "how are Qud's tiles stored?" before we extract.
//   usage: dotnet run -- inspect [assetsFile]

string data = "/Users/homefolder/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app/Contents/Resources/Data";
string assetsPath = args.Length >= 2 ? args[1] : Path.Combine(data, "resources.assets");

var am = new AssetsManager();
AssetsFileInstance inst = am.LoadAssetsFile(assetsPath, false);
AssetsFile file = inst.file;

Console.WriteLine($"file      : {Path.GetFileName(assetsPath)}");
Console.WriteLine($"unity     : {file.Metadata.UnityVersion}");
Console.WriteLine($"typetree  : {file.Metadata.TypeTreeEnabled}");
Console.WriteLine($"assets    : {file.AssetInfos.Count}");

Console.WriteLine("\n=== asset-type histogram ===");
foreach (AssetClassID cls in new[]
{
    AssetClassID.Texture2D, AssetClassID.Sprite, AssetClassID.TextAsset,
    AssetClassID.Material, AssetClassID.Mesh, AssetClassID.AudioClip,
    AssetClassID.MonoBehaviour, AssetClassID.GameObject,
})
{
    int n = file.GetAssetsOfType(cls).Count;
    if (n > 0) Console.WriteLine($"  {cls,-16} x{n}");
}

// No type tree in this build, so GetBaseField needs a tpk. But m_Name is the
// first serialized field of these assets — read it raw from each byte offset.
SampleNames(AssetClassID.Texture2D, 20);
SampleNames(AssetClassID.Sprite, 20);
SampleNames(AssetClassID.TextAsset, 12);

void SampleNames(AssetClassID cls, int max)
{
    var list = file.GetAssetsOfType(cls);
    Console.WriteLine($"\n=== {cls} names ({list.Count} total; showing {Math.Min(max, list.Count)}) ===");
    var r = file.Reader;
    int shown = 0;
    foreach (AssetFileInfo info in list)
    {
        if (shown >= max) break;
        shown++;
        try
        {
            r.Position = info.GetAbsoluteByteOffset(file);
            int len = r.ReadInt32();
            if (len < 0 || len > 1024) { Console.WriteLine($"  [{info.PathId,8}] <bad name len {len}>"); continue; }
            string name = System.Text.Encoding.UTF8.GetString(r.ReadBytes(len));
            Console.WriteLine($"  [{info.PathId,8}] {name}");
        }
        catch (Exception e) { Console.WriteLine($"  [{info.PathId,8}] <{e.GetType().Name}>"); }
    }
}
