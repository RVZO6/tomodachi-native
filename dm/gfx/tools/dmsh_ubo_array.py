#!/usr/bin/env python3
# uniform 句柄數組改為帶長度的資源表指針；與宿主一起改 ABI，不嵌入遊戲貼圖。
# Convert uniform handle arrays to bounded resource-table pointers; change the ABI with the host, without embedding game textures.
import re


def rewrite(src):
    """GameField cb3 arrays: remove only the proven descriptor-index clamps.

    Terrain uses byte offsets (layer << 8) + 272 and +296, already elements
    34 and 37 at layer zero. The translator's 32-element bound is wrong.
    A table header gives the runtime bound from the actual uniform buffer.
    A one-element declaration avoids a large static Metal resource array.
    This follows nxnative's pool_arrays layout (uint n; 8-byte resource IDs).
    """
    body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', src, re.S)
    if not body:
        return src
    arrays = {}

    def pointer(m):
        element, name = m.group(1), m.group(2)
        arrays[name] = element
        return f'constant spvUboArray_{name}* {name} [[id('

    members = re.sub(r'array<(texture\w+<[^>]+>|sampler), 32> (\w+_cb3_0(?:Smplr)?) \[\[id\(', pointer, body.group(1))
    if not arrays:
        return src
    # 指針只佔一個槽，重新編號其後成員；不能保留原 32 項數組留下的空洞。
    # A pointer occupies one slot: renumber following members, without holes from the old 32-element arrays.
    aid = 0

    def renumber(m):
        nonlocal aid
        array = re.fullmatch(r'array<.+, (\d+)>', m.group(2).strip())
        result = f'{m.group(1)}{m.group(2)} {m.group(3)} [[id({aid})]];'
        aid += int(array.group(1)) if array else 1
        return result

    members = re.sub(r'^(\s*)(.+?)\s+(\w+)\s*\[\[id\((\d+)\)\]\];', renumber, members, flags=re.M)
    definitions = {m.group(1): m for m in re.finditer(r'\b(?:u?int)\s+(_\d+)\s*=\s*([^;]+);', src)}
    clamps = set()

    def trace(name, seen):
        if name in seen or name not in definitions:
            return
        seen.add(name)
        definition = definitions[name]
        expr = definition.group(2)
        if re.fullmatch(r'min\(uint\(.+\), 31u\)', expr):
            clamps.add(name)
            return
        for dep in re.findall(r'\b_\d+\b', expr):
            trace(dep, seen)

    for name in arrays:
        for use in re.finditer(r'\.' + re.escape(name) + r'\[([^\]]+)\]', src):
            for index in re.findall(r'\b_\d+\b', use.group(1)):
                trace(index, set())
    # 只改這些數組下標的資料流，其他 min/clamp（光照、坐標、常量段）保持。
    # Change only these arrays' index data flow; retain other min/clamp operations (lighting, coordinates, constant buffers).
    for name in clamps:
        definition = definitions[name]
        expr = definition.group(2)
        src = src.replace(definition.group(0), definition.group(0).replace(expr, expr[4:-6]), 1)
    body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', src, re.S)
    structs = ''.join(f'struct spvUboArray_{name}\n{{\n    uint n;\n    array<{element}, 1> e;\n}};\n\n' for name, element in arrays.items())
    src = src[:body.start()] + structs + src[body.start():body.start(1)] + members + src[body.end(1):]
    for name in arrays:
        src = re.sub(r'([\w.]+)\.' + re.escape(name) + r'\[([^\]]+)\]',
                     lambda m: f'(&{m[1]}.{name}->e[0])[min(uint({m[2]}), {m[1]}.{name}->n)]', src)
    return src
