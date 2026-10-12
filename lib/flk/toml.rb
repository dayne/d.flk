module Flk
  # Just enough TOML for fly.toml: [tables], [[array tables]], dotted
  # table names, strings, ints, floats, bools, arrays (may span lines)
  # and inline tables. No dates, no multi-line strings.
  module TOML
    class ParseError < StandardError; end

    module_function

    def load_file(path) = parse(File.read(path))

    def parse(text)
      root = {}
      current = root
      buf = nil
      text.each_line.with_index(1) do |raw, lineno|
        line = strip_comment(raw).strip
        if buf
          buf << " " << line
          next unless balanced?(buf)
          line, buf = buf, nil
        end
        next if line.empty?

        case line
        when /\A\[\[\s*([^\[\]]+?)\s*\]\]\z/ then current = array_table(root, $1)
        when /\A\[\s*([^\[\]]+?)\s*\]\z/     then current = table(root, $1)
        when /\A([A-Za-z0-9_\-."']+?)\s*=\s*(.*)\z/
          key, val = $1, $2
          unless balanced?(val)
            buf = +line
            next
          end
          assign(current, key, parse_value(val, lineno))
        else
          raise ParseError, "line #{lineno}: can't parse: #{raw.strip}"
        end
      end
      raise ParseError, "unterminated array or inline table" if buf
      root
    end

    def strip_comment(s)
      out = +""
      q = nil
      esc = false
      s.each_char do |c|
        if q
          if esc then esc = false
          elsif c == "\\" && q == '"' then esc = true
          elsif c == q then q = nil
          end
        elsif c == '"' || c == "'" then q = c
        elsif c == "#" then break
        end
        out << c
      end
      out
    end

    def balanced?(s)
      depth = 0
      q = nil
      esc = false
      s.each_char do |c|
        if q
          if esc then esc = false
          elsif c == "\\" && q == '"' then esc = true
          elsif c == q then q = nil
          end
        elsif c == '"' || c == "'" then q = c
        elsif "[{".include?(c) then depth += 1
        elsif "]}".include?(c) then depth -= 1
        end
      end
      depth <= 0 && q.nil?
    end

    def split_key(k) = k.split(".").map { _1.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") }

    def walk(root, keys)
      keys.reduce(root) do |h, k|
        v = (h[k] ||= {})
        v = v.last if v.is_a?(Array)
        raise ParseError, "key '#{k}' is not a table" unless v.is_a?(Hash)
        v
      end
    end

    def table(root, path) = walk(root, split_key(path))

    def array_table(root, path)
      *parents, last = split_key(path)
      h = walk(root, parents)
      arr = (h[last] ||= [])
      raise ParseError, "'#{path}' is not an array of tables" unless arr.is_a?(Array)
      arr << {}
      arr.last
    end

    def assign(h, key, value)
      *parents, last = split_key(key)
      walk(h, parents)[last] = value
    end

    def parse_value(s, lineno)
      v, rest = scan_value(s)
      raise ParseError, "line #{lineno}: unexpected '#{rest.strip}'" unless rest.strip.empty?
      v
    rescue ParseError => e
      raise ParseError, e.message.start_with?("line") ? e.message : "line #{lineno}: #{e.message}"
    end

    def scan_value(s)
      s = s.lstrip
      case s
      when /\A"((?:[^"\\]|\\.)*)"/ then [unescape($1), $']
      when /\A'([^']*)'/ then [$1, $']
      when /\A(true|false)\b/ then [$1 == "true", $']
      when /\A([+-]?\d[\d_]*\.\d+(?:[eE][+-]?\d+)?)/ then [$1.delete("_").to_f, $']
      when /\A([+-]?\d[\d_]*)/ then [$1.delete("_").to_i, $']
      when /\A\[/ then scan_array(s[1..])
      when /\A\{/ then scan_inline(s[1..])
      else raise ParseError, "bad value near '#{s[0, 30]}'"
      end
    end

    def scan_array(s)
      arr = []
      loop do
        s = s.lstrip
        return [arr, s[1..]] if s.start_with?("]")
        v, s = scan_value(s)
        arr << v
        s = s.lstrip
        s = s[1..] if s.start_with?(",")
      end
    end

    def scan_inline(s)
      h = {}
      loop do
        s = s.lstrip
        return [h, s[1..]] if s.start_with?("}")
        m = s.match(/\A([A-Za-z0-9_\-"'.]+)\s*=/) or raise ParseError, "bad inline table near '#{s[0, 30]}'"
        v, s = scan_value(m.post_match)
        assign(h, m[1], v)
        s = s.lstrip
        s = s[1..] if s.start_with?(",")
      end
    end

    def unescape(s) = s.gsub(/\\(.)/) { { "n" => "\n", "t" => "\t", "r" => "\r" }[$1] || $1 }
  end
end
