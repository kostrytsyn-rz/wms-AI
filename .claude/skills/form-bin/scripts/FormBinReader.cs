// FormBinReader — 1C container (v8 file) reader + brace-format parser. Shared by form-bin and 1c-rag-forms skills.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace FormBin {
	public class Entry { public string Name; public byte[] Data; public List<Entry> Children; }

	public class Node {
		public bool IsList; public bool Quoted; public string Value; public List<Node> Items;
		public Node Parent;
		public int Count { get { return Items == null ? 0 : Items.Count; } }
		public Node this[int i] { get { return (Items != null && i < Items.Count) ? Items[i] : null; } }
		public bool IsBare(string v) { return !IsList && !Quoted && Value == v; }
		public override string ToString() { return IsList ? "{...}" : Value; }
	}

	public static class Reader {
		static bool IsContainer(byte[] d) {
			if (d.Length < 32) return false;
			if (!(d[0] == 0xFF && d[1] == 0xFF && d[2] == 0xFF && d[3] == 0x7F)) return false;
			for (int i = 4; i < 32 && i + 1 < d.Length; i++) if (d[i] == 13 && d[i + 1] == 10) return true;
			return false;
		}

		// Block header: \r\n <hex> <space> <hex> <space> <hex> <space> \r\n (hex width 8 or 16)
		static void Header(byte[] d, long off, out long total, out long size, out long next, out int hlen) {
			int w = 0; long p = off + 2;
			while (p + w < d.Length && d[p + w] != 32) w++;
			Func<long, long> hex = (s) => Convert.ToInt64(Encoding.ASCII.GetString(d, (int)s, w), 16);
			total = hex(p); size = hex(p + w + 1); next = hex(p + 2 * w + 2);
			hlen = 2 + 3 * (w + 1) + 2;
		}

		static byte[] ReadBlock(byte[] d, long off, out int addrWidth) {
			long total, size, next; int hlen;
			Header(d, off, out total, out size, out next, out hlen);
			addrWidth = (hlen == 31) ? 4 : 8;
			long end = addrWidth == 4 ? 0x7FFFFFFFL : 0x7FFFFFFFFFFFFFFFL;
			var ms = new MemoryStream();
			long remaining = total; long cur = off;
			while (true) {
				int take = (int)Math.Min(size, remaining);
				ms.Write(d, (int)(cur + hlen), take);
				remaining -= take;
				if (remaining <= 0 || next == end || next == 0xFFFFFFFFL) break;
				cur = next;
				Header(d, cur, out total, out size, out next, out hlen);
			}
			return ms.ToArray();
		}

		static byte[] MaybeInflate(byte[] b) {
			if (b.Length == 0) return b;
			if (b[0] == 0xEF || b[0] == (byte)'{' || IsContainer(b)) return b;
			try {
				using (var src = new MemoryStream(b))
				using (var z = new DeflateStream(src, CompressionMode.Decompress))
				using (var dst = new MemoryStream()) { z.CopyTo(dst); var r = dst.ToArray(); return r.Length > 0 ? r : b; }
			} catch { return b; }
		}

		public static List<Entry> Unpack(byte[] d) {
			var res = new List<Entry>();
			long first = -1;
			for (int i = 4; i < 40; i++) if (d[i] == 13 && d[i + 1] == 10) { first = i; break; }
			int aw;
			byte[] toc = ReadBlock(d, first, out aw);
			int step = aw * 3;
			for (int i = 0; i + step <= toc.Length; i += step) {
				long a = aw == 4 ? BitConverter.ToUInt32(toc, i) : BitConverter.ToInt64(toc, i);
				long c = aw == 4 ? BitConverter.ToUInt32(toc, i + aw) : BitConverter.ToInt64(toc, i + aw);
				if (a == 0x7FFFFFFFL || a == 0 || a >= d.Length) break;
				int tmp;
				byte[] attr = ReadBlock(d, a, out tmp);
				string name = attr.Length > 20 ? Encoding.Unicode.GetString(attr, 20, attr.Length - 20).TrimEnd('\0') : "?";
				byte[] body = MaybeInflate(ReadBlock(d, c, out tmp));
				var e = new Entry { Name = name, Data = body };
				if (IsContainer(body)) e.Children = Unpack(body);
				res.Add(e);
			}
			return res;
		}

		public static string Text(byte[] b) {
			int start = (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0;
			return Encoding.UTF8.GetString(b, start, b.Length - start);
		}

		public static Node Parse(string s) {
			var root = new Node { IsList = true, Items = new List<Node>() };
			var cur = root; int i = 0, n = s.Length;
			var sb = new StringBuilder();
			while (i < n) {
				char ch = s[i];
				if (ch == '{') { var l = new Node { IsList = true, Items = new List<Node>(), Parent = cur }; cur.Items.Add(l); cur = l; i++; }
				else if (ch == '}') { if (cur.Parent != null) cur = cur.Parent; i++; }
				else if (ch == ',' || ch == '\r' || ch == '\n' || ch == ' ' || ch == '\t' || ch == '﻿') { i++; }
				else if (ch == '"') {
					sb.Clear(); i++;
					while (i < n) {
						if (s[i] == '"') { if (i + 1 < n && s[i + 1] == '"') { sb.Append('"'); i += 2; continue; } i++; break; }
						sb.Append(s[i]); i++;
					}
					cur.Items.Add(new Node { Quoted = true, Value = sb.ToString(), Parent = cur });
				}
				else {
					int st = i;
					while (i < n && s[i] != ',' && s[i] != '}' && s[i] != '{' && s[i] != '\r' && s[i] != '\n') i++;
					cur.Items.Add(new Node { Value = s.Substring(st, i - st).Trim(), Parent = cur });
				}
			}
			return root.Count == 1 && root[0].IsList ? root[0] : root;
		}
	}
}
