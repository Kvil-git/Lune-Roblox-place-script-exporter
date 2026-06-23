--!strict
--
-- REQUIRES
--
local serde  = require("@lune/serde")
local stdio  = require("@lune/stdio")
local fs     = require("@lune/fs")
local roblox = require("@lune/roblox")
--
-- CONSTANTS
--
local PLACE_FILE: string = stdio.prompt(
    "text",
    "Input the place file name to deserialize. It should be stored in the same directory as this script."
)
local output_folder       = `./scripts`
local included_classnames = {
    ["Script"]        = ".server.luau",
    ["ServerScript"]  = ".server.luau",
    ["LocalScript"]   = ".client.luau",
    ["ModuleScript"]  = ".luau",
}
--
-- LOCAL FUNCTIONS
--
local function Replace_Xml_With_Ascii(str: string): string
    local patterns = {
        { "%<%!%[CDATA%[", " "},
        { "%]%]>"," "},
        { "&Space;", " " },
        { "&Tab;", "\t" },
        { "&NewLine;", "\n" },
        { "&excl;", "!" },
        { "&quot;", "\"" },
        { "&num;", "#" },
        { "&dollar;", "$" },
        { "&percnt;", "%" },
        { "&amp;", "&" },
        { "&apos;", "'" },
        { "&lpar;", "(" },
        { "&rpar;", ")" },
        { "&ast;", "*" },
        { "&plus;", "+" },
        { "&comma;", "," },
        { "&period;", "." },
        { "&sol;", "/" },
        { "&colon;", ":" },
        { "&semi;", ";" },
        { "&lt;", "<" },
        { "&gt;", ">" },
        { "&equals;", "=" },
        { "&quest;", "?" },
        { "&commat;", "@" },
        { "&lsqb;", "[" },
        { "&lbrack;", "[" },
        { "&rsqb;", "]" },
        { "&rbrack;", "]" },
        { "&Hat;", "^" },
        { "&lowbar;", "_" },
        { "&UnderBar;", "_" },
        { "&grave;", "`" },
        { "&lcub;", "{" },
        { "&lbrace;", "{" },
        { "&rcub;", "}" },
        { "&rbrace;", "}" },
        { "&nbsp;", " " },
        { "&NonBreakingSpace;", " " },
        { "&hyphen;", "-" },
        { "&dash;", "-" },
    }
    
    local result = str
    for _, pattern in ipairs(patterns) do
        local entity       = pattern[1]
        local replacement  = pattern[2]
        result = string.gsub(result, entity, replacement)
    end
    return result
end

-- Builds a folder path from the root DataModel up to (but not including) the given instance.
local function Get_Path_From_Instance(instance: roblox.Instance, root: roblox.DataModel): string
    local path   = output_folder
    local stack  = {}
    local parent = instance.Parent
    while ((parent ~= root) and (parent ~= nil)) do
        table.insert(stack, parent.Name or parent.ClassName)
        parent = parent.Parent
    end
    for i = #stack, 1, -1 do
        path = `{path}/{stack[i]}`
    end
    return path
end

-- Extracts the Lua source code from the serialized XML of a script instance.
local function Extract_Module_From_XML(xml: string): string
    local prefix    = `<string name="Source">`
    local increment = string.len(prefix)
    local starting  = xml:find(prefix)
    if (starting == nil) then
        return ""
    end
    local substr = xml:sub(starting + increment)
    local ending = substr:find("</string>")
    if (ending == nil) then
        return ""
    end
    local output = substr:sub(1, ending - 1)
    output = Replace_Xml_With_Ascii(output)
    return output
end

--
-- Converts a single property element from serialized XML to a JSON‑compatible Lua value.
--
local function Convert_Xml_Value_To_Json(element_type: string, inner_xml: string): any
    -- Helper: split a string by commas and convert to numbers.
    local function Split_Numbers(text: string): {number}
        local parts = {}
        for part in string.gmatch(text, "[^,%s]+") do
            local num = tonumber(part)
            if (num ~= nil) then
                table.insert(parts, num)
            end
        end
        return parts
    end

    if     (element_type == "string") then
        return inner_xml
    elseif (element_type == "bool") then
        return (inner_xml == "true")
    elseif ((element_type == "int") or (element_type == "float") or (element_type == "double")) then
        return tonumber(inner_xml)
    elseif (element_type == "token") then
        return inner_xml
    elseif (element_type == "Color3") then
        local nums = Split_Numbers(inner_xml)
        return nums  -- [r, g, b]
    elseif (element_type == "BrickColor") then
        return tonumber(inner_xml)
    elseif (element_type == "UDim2") then
        local s1, o1, s2, o2 = string.match(inner_xml, "<S>(.-)</S><O>(.-)</O>%s*<S>(.-)</S><O>(.-)</O>")
        return {
            { tonumber(s1), tonumber(o1) },
            { tonumber(s2), tonumber(o2) },
        }
    elseif (element_type == "UDim") then
        local s, o = string.match(inner_xml, "<S>(.-)</S><O>(.-)</O>")
        return { tonumber(s), tonumber(o) }
    elseif (element_type == "Vector3") then
        return Split_Numbers(inner_xml)  -- [x, y, z]
    elseif (element_type == "Vector2") then
        return Split_Numbers(inner_xml)  -- [x, y]
    elseif (element_type == "CFrame") then
        return Split_Numbers(inner_xml)  -- 12 numbers
    else
        -- For any unknown type, fall back to the raw text.
        return inner_xml
    end
end

--
-- Parses the serialized XML of a single Roblox instance and returns a table
-- of its properties (excluding "Name") ready for JSON encoding.
--
local function Extract_Properties_From_Serialized_XML(xml: string): { [string]: any }
    local properties = {}
    -- Find the first <Properties> block.
    local prop_start  = xml:find("<Properties>")
    if (prop_start == nil) then
        return properties
    end
    local prop_end    = xml:find("</Properties>", prop_start)
    if (prop_end == nil) then
        return properties
    end
    local props_block = xml:sub(prop_start + 12, prop_end - 1)

    -- Match each property element.  The pattern captures the whole element,
    -- the tag name, the attribute name, and the inner content (which may span lines).
    for whole_elem, elem_type, prop_name, inner_content in string.gmatch(props_block,
        "(<(%w+) name=\"([^\"]+)\">([%s%S]-)</%2>)"
    ) do
        if (prop_name ~= "Name") then
            local value = Convert_Xml_Value_To_Json(elem_type, inner_content)
            properties[prop_name] = value
        end
    end
    return properties
end

--
-- Writes an init.meta.json file for a non‑script instance, creating the
-- necessary folder (named after the instance) first.
--
local function Write_Instance_Meta(instance: roblox.Instance, root: roblox.DataModel): ()
    local parent_path    = Get_Path_From_Instance(instance, root)
    local instance_folder = `{parent_path}/{instance.Name}`

    -- Serialize the instance alone (descendants are irrelevant for meta).
    local serialized_xml = roblox.serializeModel({instance}, true)
    local properties     = Extract_Properties_From_Serialized_XML(serialized_xml)

    local meta = {
        className  = instance.ClassName,
        properties = properties,
    }

    pcall(function()
        fs.writeDir(instance_folder)
    end)
    local meta_file_path = `{instance_folder}/init.meta.json`
    local prettify = true
    fs.writeFile(meta_file_path, serde.encode("json", meta, prettify))
end

--
-- MODULE OPERATION
--
local place_contents = fs.readFile(PLACE_FILE)
local place          = roblox.deserializePlace(place_contents)

for _, descendant in place:GetDescendants() do
    --
    -- Skip destroyed instances.
    --
    if (not descendant) then
        continue
    end
    --
    -- Skip services (direct children of the DataModel).
    --
    if (descendant.Parent == place) then
        continue
    end

    local extension = included_classnames[descendant.ClassName]
    if (extension) then
        -- Script instance: extract source and write as a module file.
        local path            = Get_Path_From_Instance(descendant, place)
        local serialized      = roblox.serializeModel({descendant}, true)
        local source_code     = Extract_Module_From_XML(serialized)
        pcall(function()
            fs.writeDir(path)
        end)
        local file_name = `{descendant.Name}{extension}`
        fs.writeFile(`{path}/{file_name}`, source_code)
    else
        -- Non‑script instance: create a folder with an init.meta.json.
        Write_Instance_Meta(descendant, place)
    end
end
