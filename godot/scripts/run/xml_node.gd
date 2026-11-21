class_name XmlNode
extends RefCounted
## Tolerant XML tree for FTL's data files (multiple roots, `<FTL>` wrappers, stray closing tags, spaces around
## `=`). Comments are stripped first (FtlData.strip_comments). Pure data: no FTL content lives in the project.

var tag := ""
var attrs := {}
var children: Array[XmlNode] = []
var text := ""  # concatenated direct text content (stripped)


func attr(name: String, default := "") -> String:
	return String(attrs.get(name, default))


func has_attr(name: String) -> bool:
	return attrs.has(name)


func child(t: String) -> XmlNode:
	for c in children:
		if c.tag == t:
			return c
	return null


func children_named(t: String) -> Array[XmlNode]:
	var out: Array[XmlNode] = []
	for c in children:
		if c.tag == t:
			out.append(c)
	return out


const _TAG_RE := "<(/?)([A-Za-z_][\\w.:-]*)((?:[^>\"]|\"[^\"]*\")*?)(/?)>"
const _ATTR_RE := "([\\w:-]+)\\s*=\\s*\"([^\"]*)\""
static var _tag_re: RegEx
static var _attr_re: RegEx


## Parses `src` and returns a virtual root whose children are the top-level elements. A top-level `<FTL>`
## wrapper is flattened (its children become top-level).
static func parse(src: String) -> XmlNode:
	if _tag_re == null:
		_tag_re = RegEx.create_from_string(_TAG_RE)
		_attr_re = RegEx.create_from_string(_ATTR_RE)
	src = FtlData.strip_comments(src)
	src = RegEx.create_from_string("<\\?[\\s\\S]*?\\?>").sub(src, "", true)
	var root := XmlNode.new()
	root.tag = "#root"
	var stack: Array[XmlNode] = [root]
	var last := 0
	for m in _tag_re.search_all(src):
		var between := src.substr(last, m.get_start() - last).strip_edges()
		if between != "":
			var top := stack[-1]
			top.text = between if top.text == "" else top.text + " " + between
		last = m.get_end()
		var name := m.get_string(2)
		if m.get_string(1) == "/":
			# close: pop to the matching open tag; an unmatched close tag is ignored
			for i in range(stack.size() - 1, 0, -1):
				if stack[i].tag == name:
					stack.resize(i)
					break
			continue
		var n := XmlNode.new()
		n.tag = name
		for a in _attr_re.search_all(m.get_string(3)):
			n.attrs[a.get_string(1)] = a.get_string(2)
		stack[-1].children.append(n)
		if m.get_string(4) != "/":
			stack.append(n)
	# Flatten <FTL> wrappers.
	var flat: Array[XmlNode] = []
	for c in root.children:
		if c.tag == "FTL":
			flat.append_array(c.children)
		else:
			flat.append(c)
	root.children = flat
	return root
