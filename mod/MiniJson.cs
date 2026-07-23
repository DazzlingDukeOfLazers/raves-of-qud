using System.Collections.Generic;
using System.Text;

namespace RavesOfQud
{
    /// <summary>
    /// Intentionally tiny reader: parses a FLAT JSON object of string/number/bool
    /// values into a string dictionary. Enough for command messages coming from
    /// Godot ({ "type":"command", "name":"move", "dir":"N" }); NOT a general parser.
    /// </summary>
    public static class MiniJson
    {
        public static Dictionary<string, string> ParseFlat(string s)
        {
            var d = new Dictionary<string, string>();
            if (string.IsNullOrEmpty(s)) return d;
            int i = 0;
            SkipWs(s, ref i);
            if (i >= s.Length || s[i] != '{') return d;
            i++;
            while (i < s.Length)
            {
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == '}') break;
                string key = ReadString(s, ref i);
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == ':') i++;
                SkipWs(s, ref i);
                d[key] = ReadValue(s, ref i);
                SkipWs(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') break;
            }
            return d;
        }

        private static void SkipWs(string s, ref int i)
        {
            while (i < s.Length && char.IsWhiteSpace(s[i])) i++;
        }

        private static string ReadString(string s, ref int i)
        {
            var sb = new StringBuilder();
            if (i >= s.Length || s[i] != '"') return "";
            i++;
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') break;
                if (c == '\\' && i < s.Length)
                {
                    char e = s[i++];
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 't': sb.Append('\t'); break;
                        case 'r': sb.Append('\r'); break;
                        case '"': sb.Append('"');  break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/');  break;
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
            }
            return sb.ToString();
        }

        private static string ReadValue(string s, ref int i)
        {
            if (i < s.Length && s[i] == '"') return ReadString(s, ref i);
            var sb = new StringBuilder();
            while (i < s.Length && s[i] != ',' && s[i] != '}') sb.Append(s[i++]);
            return sb.ToString().Trim();
        }
    }
}
