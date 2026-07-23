using System.Globalization;
using System.Text;

namespace RavesOfQud
{
    /// <summary>
    /// Minimal, dependency-free JSON writer (objects, arrays, strings, ints, bools,
    /// null). Deliberately avoids Newtonsoft so the mod compiles with no external
    /// reference. Correct string escaping; not a general-purpose serializer.
    ///
    /// Usage:
    ///   var j = new JsonWriter();
    ///   j.BeginObject().Member("type", "snapshot").Name("cells").BeginArray()...
    /// </summary>
    public sealed class JsonWriter
    {
        private readonly StringBuilder _sb = new StringBuilder(8192);
        private bool _needComma;

        public JsonWriter BeginObject() { Sep(); _sb.Append('{'); _needComma = false; return this; }
        public JsonWriter EndObject()   { _sb.Append('}'); _needComma = true;  return this; }
        public JsonWriter BeginArray()  { Sep(); _sb.Append('['); _needComma = false; return this; }
        public JsonWriter EndArray()    { _sb.Append(']'); _needComma = true;  return this; }

        /// <summary>Write an object key. The next Value/Begin* supplies its value.</summary>
        public JsonWriter Name(string name) { Sep(); WriteString(name); _sb.Append(':'); _needComma = false; return this; }

        public JsonWriter Value(string s) { Sep(); WriteString(s); _needComma = true; return this; }
        public JsonWriter Value(int n)    { Sep(); _sb.Append(n.ToString(CultureInfo.InvariantCulture)); _needComma = true; return this; }
        public JsonWriter Value(bool b)   { Sep(); _sb.Append(b ? "true" : "false"); _needComma = true; return this; }
        public JsonWriter Null()          { Sep(); _sb.Append("null"); _needComma = true; return this; }

        public JsonWriter Member(string name, string v) { Name(name); return v == null ? Null() : Value(v); }
        public JsonWriter Member(string name, int v)    { Name(name); return Value(v); }
        public JsonWriter Member(string name, bool v)   { Name(name); return Value(v); }

        private void Sep() { if (_needComma) _sb.Append(','); }

        private void WriteString(string s)
        {
            _sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"':  _sb.Append("\\\""); break;
                    case '\\': _sb.Append("\\\\"); break;
                    case '\n': _sb.Append("\\n");  break;
                    case '\r': _sb.Append("\\r");  break;
                    case '\t': _sb.Append("\\t");  break;
                    case '\b': _sb.Append("\\b");  break;
                    case '\f': _sb.Append("\\f");  break;
                    default:
                        if (c < 0x20)
                            _sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else
                            _sb.Append(c);
                        break;
                }
            }
            _sb.Append('"');
        }

        public override string ToString() => _sb.ToString();
    }
}
