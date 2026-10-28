--!strict
--!optimize 2
--[[
	Types: the buffer codecs a packet's data is declared with (`Net.types`, usually `local t`).

		u8 u16 u32 / i8 i16 i32   1, 2, 4 bytes  out-of-range values error on send
		f32 f64                   4, 8           NaN and infinity rejected
		bool                      1
		string(max)               1-2 + length   longer than max errors on send, rejected on the server
		vector3                   12
		unitVector                4              a direction (aim, shot, normal), octahedral
		angle                     2              radians, 0.0055 degree steps, decodes to (-pi, pi]
		cframe                    19             position + a smallest-three quaternion
		instance(class?)          0              rides beside the buffer, read back in order
		enum({ ... })             1              a list of strings, sent as its index
		optional(T)               1 + T
		array(T, max)             1-2 + n * T
		struct({ ... })           sum of fields  field names are never sent

	Any number type takes a range the server enforces: `t.u8({ max = 5 })`, `t.f32({ min = 0, max = 1 })`.

	Writing checks every value and errors with its path ("Fire.origin: expected a Vector3, got nil").
	Reading is bounds-checked; on the server (strict) it also rejects anything a real client could
	not have sent. An instance that no longer exists on the server marks the packet stale, which
	drops it quietly instead of counting a strike (it was probably destroyed in flight).
]]

export type Writer = {
	buf: buffer,
	cursor: number,
	instances: { Instance },
	instanceCount: number,
}

export type Reader = {
	buf: buffer,
	cursor: number,
	len: number,
	instances: { [number]: any },
	instanceCursor: number,
	strict: boolean,
	stale: boolean,
}

export type Codec<T> = {
	name: string,
	fixed: number?,
	max: number,
	maxInstances: number,
	write: (w: Writer, value: T, path: string) -> (),
	read: (r: Reader) -> T,
}

type Range = { min: number?, max: number? }

local Types = {}

local CODEC = table.freeze({})
local TAU = 2 * math.pi
local SQRT2 = math.sqrt(2)
local F32_MAX = 3.4028234663852886e38

function Types.newWriter(size: number?): Writer
	return { buf = buffer.create(size or 256), cursor = 0, instances = {}, instanceCount = 0 }
end

function Types.reset(w: Writer)
	w.cursor = 0
	if w.instanceCount > 0 then
		table.clear(w.instances)
		w.instanceCount = 0
	end
end

local function reserve(w: Writer, n: number)
	local need = w.cursor + n
	local len = buffer.len(w.buf)
	if need > len then
		local grown = buffer.create(math.max(len * 2, need))
		buffer.copy(grown, 0, w.buf, 0, w.cursor)
		w.buf = grown
	end
end
Types.reserve = reserve

local function need(r: Reader, n: number)
	if r.cursor + n > r.len then
		error("ran past the end of the batch", 0)
	end
end

function Types.isCodec(value: any): boolean
	return type(value) == "table" and rawget(value, "_codec") == CODEC
end

local function codec<T>(fields: any): Codec<T>
	fields._codec = CODEC
	return fields :: Codec<T>
end

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

local function describe(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return `"{value}"`
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	end
	return kind
end

local roundScratch = buffer.create(4)
local function toF32(x: number): number
	buffer.writef32(roundScratch, 0, x)
	return buffer.readf32(roundScratch, 0)
end

--[[ Numbers. Each is a codec and can be called with { min, max } for a narrower range. `round` is
	what the wire does to a value (f32 only): the server checks the range against rounded bounds,
	so 0.3 sent as an f32 (0.30000001) still fits { max = 0.3 }. ]]
local function number(name: string, bytes: number, lo: number, hi: number, integer: boolean, writeFn: any, readFn: any, round: ((number) -> number)?)
	local function make(range: Range?): any
		local min, max = lo, hi
		if range ~= nil then
			if type(range) ~= "table" then
				error(`t.{name}(...) takes a range table: \{ min = ..., max = ... \}`, 3)
			end
			for key in range :: any do
				if key ~= "min" and key ~= "max" then
					error(`t.{name}: unknown range key "{tostring(key)}"; use min and max`, 3)
				end
			end
			min = range.min or lo
			max = range.max or hi
			if min < lo or max > hi or min > max then
				error(`t.{name}: range {min} to {max} does not fit {name} ({lo} to {hi})`, 3)
			end
		end
		local label = if range then `{name}(\{ min = {min}, max = {max} \})` else name
		local readMin, readMax = min, max
		if round then
			readMin, readMax = round(min), round(max)
		end
		local self = codec({
			name = label,
			fixed = bytes,
			max = bytes,
			maxInstances = 0,
			write = function(w: Writer, v: any, path: string)
				if type(v) ~= "number" then
					error(`{path}: expected a number for {label}, got {describe(v)}`, 0)
				end
				if integer then
					if v ~= math.floor(v) then
						error(`{path}: {v} is not a whole number ({label})`, 0)
					end
				elseif not finite(v) then
					error(`{path}: {v} is not a finite number`, 0)
				end
				if v < min or v > max then
					error(`{path}: {v} is outside {label}'s range {min} to {max}`, 0)
				end
				reserve(w, bytes)
				writeFn(w.buf, w.cursor, v)
				w.cursor += bytes
			end,
			read = function(r: Reader): any
				need(r, bytes)
				local v = readFn(r.buf, r.cursor)
				r.cursor += bytes
				if r.strict and (not finite(v) or v < readMin or v > readMax) then
					error(`{label}: {v} is out of range`, 0)
				end
				return v
			end,
		})
		return setmetatable(self, {
			__call = function(_, newRange: Range)
				return make(newRange)
			end,
		})
	end
	return make(nil)
end

Types.u8 = number("u8", 1, 0, 255, true, buffer.writeu8, buffer.readu8) :: Codec<number> & ((Range) -> Codec<number>)
Types.u16 = number("u16", 2, 0, 65535, true, buffer.writeu16, buffer.readu16) :: Codec<number> & ((Range) -> Codec<number>)
Types.u32 = number("u32", 4, 0, 4294967295, true, buffer.writeu32, buffer.readu32) :: Codec<number> & ((Range) -> Codec<number>)
Types.i8 = number("i8", 1, -128, 127, true, buffer.writei8, buffer.readi8) :: Codec<number> & ((Range) -> Codec<number>)
Types.i16 = number("i16", 2, -32768, 32767, true, buffer.writei16, buffer.readi16) :: Codec<number> & ((Range) -> Codec<number>)
Types.i32 = number("i32", 4, -2147483648, 2147483647, true, buffer.writei32, buffer.readi32) :: Codec<number> & ((Range) -> Codec<number>)
Types.f32 = number("f32", 4, -F32_MAX, F32_MAX, false, buffer.writef32, buffer.readf32, toF32) :: Codec<number> & ((Range) -> Codec<number>)
Types.f64 = number("f64", 8, -math.huge, math.huge, false, buffer.writef64, buffer.readf64) :: Codec<number> & ((Range) -> Codec<number>)

Types.bool = codec({
	name = "bool",
	fixed = 1,
	max = 1,
	maxInstances = 0,
	write = function(w: Writer, v: any, path: string)
		if type(v) ~= "boolean" then
			error(`{path}: expected a boolean, got {describe(v)}`, 0)
		end
		reserve(w, 1)
		buffer.writeu8(w.buf, w.cursor, if v then 1 else 0)
		w.cursor += 1
	end,
	read = function(r: Reader): any
		need(r, 1)
		local byte = buffer.readu8(r.buf, r.cursor)
		r.cursor += 1
		if byte > 1 and r.strict then
			error("bool: not 0 or 1", 0)
		end
		return byte == 1
	end,
}) :: Codec<boolean>

local function lengthWriter(max: number): (number, any, any)
	if max > 255 then
		return 2, buffer.writeu16, buffer.readu16
	end
	return 1, buffer.writeu8, buffer.readu8
end

function Types.string(max: number): Codec<string>
	if type(max) ~= "number" or max < 1 or max > 65535 or max ~= math.floor(max) then
		error("t.string(max) takes the longest length allowed, 1 to 65535 bytes", 2)
	end
	local prefix, writeLength, readLength = lengthWriter(max)
	local label = `string({max})`
	return codec({
		name = label,
		max = prefix + max,
		maxInstances = 0,
		write = function(w: Writer, v: any, path: string)
			if type(v) ~= "string" then
				error(`{path}: expected a string, got {describe(v)}`, 0)
			end
			local n = #v
			if n > max then
				error(`{path}: {n} bytes is longer than {label}`, 0)
			end
			if utf8.len(v) == nil then
				error(`{path}: not valid UTF-8 (the server would refuse it)`, 0)
			end
			reserve(w, prefix + n)
			writeLength(w.buf, w.cursor, n)
			buffer.writestring(w.buf, w.cursor + prefix, v)
			w.cursor += prefix + n
		end,
		read = function(r: Reader): any
			need(r, prefix)
			local n = readLength(r.buf, r.cursor)
			r.cursor += prefix
			if n > max and r.strict then
				error(`{label}: {n} bytes is too long`, 0)
			end
			need(r, n)
			local s = buffer.readstring(r.buf, r.cursor, n)
			r.cursor += n
			if r.strict and utf8.len(s) == nil then
				error(`{label}: not valid UTF-8`, 0)
			end
			return s
		end,
	})
end

local function readVector3(r: Reader): Vector3
	need(r, 12)
	local b, c = r.buf, r.cursor
	local x, y, z = buffer.readf32(b, c), buffer.readf32(b, c + 4), buffer.readf32(b, c + 8)
	r.cursor += 12
	if r.strict and not (finite(x) and finite(y) and finite(z)) then
		error("vector3: not finite", 0)
	end
	return Vector3.new(x, y, z)
end

local function writeVector3(w: Writer, v: Vector3, path: string)
	if not (finite(v.X) and finite(v.Y) and finite(v.Z)) then
		error(`{path}: {v} is not finite`, 0)
	end
	reserve(w, 12)
	local b, c = w.buf, w.cursor
	buffer.writef32(b, c, v.X)
	buffer.writef32(b, c + 4, v.Y)
	buffer.writef32(b, c + 8, v.Z)
	w.cursor += 12
end

Types.vector3 = codec({
	name = "vector3",
	fixed = 12,
	max = 12,
	maxInstances = 0,
	write = function(w: Writer, v: any, path: string)
		if typeof(v) ~= "Vector3" then
			error(`{path}: expected a Vector3, got {describe(v)}`, 0)
		end
		writeVector3(w, v, path)
	end,
	read = readVector3,
}) :: Codec<Vector3>

local function signNotZero(x: number): number
	return if x >= 0 then 1 else -1
end

local function snorm16(x: number): number
	return math.clamp(math.round(x * 32767), -32767, 32767)
end

-- Octahedral: the unit sphere folded onto a square, two 16-bit coordinates.
Types.unitVector = codec({
	name = "unitVector",
	fixed = 4,
	max = 4,
	maxInstances = 0,
	write = function(w: Writer, v: any, path: string)
		if typeof(v) ~= "Vector3" then
			error(`{path}: expected a Vector3 direction, got {describe(v)}`, 0)
		end
		local x, y, z = v.X, v.Y, v.Z
		local l1 = math.abs(x) + math.abs(y) + math.abs(z)
		if not (l1 > 0 and finite(l1)) then
			error(`{path}: a direction cannot be {v}`, 0)
		end
		local px, py = x / l1, y / l1
		if z < 0 then
			px, py = (1 - math.abs(py)) * signNotZero(px), (1 - math.abs(px)) * signNotZero(py)
		end
		reserve(w, 4)
		buffer.writei16(w.buf, w.cursor, snorm16(px))
		buffer.writei16(w.buf, w.cursor + 2, snorm16(py))
		w.cursor += 4
	end,
	read = function(r: Reader): any
		need(r, 4)
		local px = math.max(buffer.readi16(r.buf, r.cursor), -32767) / 32767
		local py = math.max(buffer.readi16(r.buf, r.cursor + 2), -32767) / 32767
		r.cursor += 4
		local z = 1 - math.abs(px) - math.abs(py)
		local x, y = px, py
		if z < 0 then
			x, y = (1 - math.abs(py)) * signNotZero(px), (1 - math.abs(px)) * signNotZero(py)
		end
		return Vector3.new(x, y, z).Unit
	end,
}) :: Codec<Vector3>

Types.angle = codec({
	name = "angle",
	fixed = 2,
	max = 2,
	maxInstances = 0,
	write = function(w: Writer, v: any, path: string)
		if type(v) ~= "number" or not finite(v) then
			error(`{path}: expected an angle in radians, got {describe(v)}`, 0)
		end
		reserve(w, 2)
		buffer.writeu16(w.buf, w.cursor, math.round((v % TAU) / TAU * 65536) % 65536)
		w.cursor += 2
	end,
	read = function(r: Reader): any
		need(r, 2)
		local a = buffer.readu16(r.buf, r.cursor) / 65536 * TAU
		r.cursor += 2
		return if a > math.pi then a - TAU else a
	end,
}) :: Codec<number>

local function quaternion(cf: CFrame): (number, number, number, number)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = math.sqrt(1 + trace) * 2
		return (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		return 0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		return (r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s
	end
	local s = math.sqrt(1 + r22 - r00 - r11) * 2
	return (r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s
end

-- Position (3 x f32), then the rotation as smallest-three: which of x, y, z, w is largest (1 byte)
-- and the other three as 16-bit values. 19 bytes against 48 for a raw CFrame.
Types.cframe = codec({
	name = "cframe",
	fixed = 19,
	max = 19,
	maxInstances = 0,
	write = function(w: Writer, v: any, path: string)
		if typeof(v) ~= "CFrame" then
			error(`{path}: expected a CFrame, got {describe(v)}`, 0)
		end
		writeVector3(w, v.Position, path)
		local q = { quaternion(v) }
		local largest, size = 1, math.abs(q[1])
		for i = 2, 4 do
			if math.abs(q[i]) > size then
				largest, size = i, math.abs(q[i])
			end
		end
		local sign = if q[largest] < 0 then -1 else 1
		reserve(w, 7)
		local b, c = w.buf, w.cursor
		buffer.writeu8(b, c, largest - 1)
		local offset = 1
		for i = 1, 4 do
			if i ~= largest then
				buffer.writei16(b, c + offset, snorm16(q[i] * sign * SQRT2))
				offset += 2
			end
		end
		w.cursor += 7
	end,
	read = function(r: Reader): any
		local position = readVector3(r)
		need(r, 7)
		local b, c = r.buf, r.cursor
		local largest = buffer.readu8(b, c) + 1
		if largest > 4 then
			if r.strict then
				error("cframe: bad rotation index", 0)
			end
			largest = 4
		end
		local q = table.create(4, 0)
		local sum = 0
		local offset = 1
		for i = 1, 4 do
			if i ~= largest then
				local value = math.max(buffer.readi16(b, c + offset), -32767) / 32767 / SQRT2
				q[i] = value
				sum += value * value
				offset += 2
			end
		end
		q[largest] = math.sqrt(math.max(0, 1 - sum))
		r.cursor += 7
		return CFrame.new(position.X, position.Y, position.Z, q[1], q[2], q[3], q[4])
	end,
}) :: Codec<CFrame>

function Types.instance(class: string?): Codec<Instance>
	if class ~= nil and type(class) ~= "string" then
		error("t.instance(class?) takes a class name such as \"Model\"", 2)
	end
	local label = if class then `instance("{class}")` else "instance"
	return codec({
		name = label,
		fixed = 0,
		max = 0,
		maxInstances = 1,
		write = function(w: Writer, v: any, path: string)
			if typeof(v) ~= "Instance" then
				error(`{path}: expected an Instance, got {describe(v)}`, 0)
			end
			if class and not v:IsA(class) then
				error(`{path}: {v:GetFullName()} is a {v.ClassName}, not a {class}`, 0)
			end
			w.instanceCount += 1
			w.instances[w.instanceCount] = v
		end,
		read = function(r: Reader): any
			r.instanceCursor += 1
			local v = r.instances[r.instanceCursor]
			if typeof(v) ~= "Instance" then
				if r.strict then
					if v ~= nil then
						error(`{label}: not an Instance`, 0)
					end
					r.stale = true
				end
				return nil
			end
			if class and not v:IsA(class) then
				if r.strict then
					error(`{label}: got a {v.ClassName}`, 0)
				end
				return nil
			end
			return v
		end,
	})
end

function Types.enum(values: { string }): Codec<string>
	if type(values) ~= "table" or #values == 0 or #values > 255 then
		error("t.enum takes a list of 1 to 255 strings", 2)
	end
	local index: { [string]: number } = {}
	for i, value in values do
		if type(value) ~= "string" then
			error("t.enum takes a list of strings", 2)
		end
		if index[value] then
			error(`t.enum lists "{value}" twice`, 2)
		end
		index[value] = i
	end
	local list = table.clone(values)
	local label = `enum(\{ {table.concat(list, ", ")} \})`
	return codec({
		name = label,
		fixed = 1,
		max = 1,
		maxInstances = 0,
		write = function(w: Writer, v: any, path: string)
			local i = index[v]
			if not i then
				error(`{path}: {describe(v)} is not one of {table.concat(list, ", ")}`, 0)
			end
			reserve(w, 1)
			buffer.writeu8(w.buf, w.cursor, i)
			w.cursor += 1
		end,
		read = function(r: Reader): any
			need(r, 1)
			local value = list[buffer.readu8(r.buf, r.cursor)]
			r.cursor += 1
			if value == nil and r.strict then
				error(`{label}: index out of range`, 0)
			end
			return value
		end,
	})
end

function Types.optional<T>(inner: Codec<T>): Codec<T?>
	if not Types.isCodec(inner) then
		error("t.optional takes a type, such as t.optional(t.u8)", 2)
	end
	return codec({
		name = `optional({inner.name})`,
		max = 1 + inner.max,
		maxInstances = inner.maxInstances,
		write = function(w: Writer, v: any, path: string)
			reserve(w, 1)
			if v == nil then
				buffer.writeu8(w.buf, w.cursor, 0)
				w.cursor += 1
			else
				buffer.writeu8(w.buf, w.cursor, 1)
				w.cursor += 1
				inner.write(w, v, path)
			end
		end,
		read = function(r: Reader): any
			need(r, 1)
			local present = buffer.readu8(r.buf, r.cursor)
			r.cursor += 1
			if present == 0 then
				return nil
			elseif present ~= 1 and r.strict then
				error("optional: not 0 or 1", 0)
			end
			return inner.read(r)
		end,
	})
end

function Types.array<T>(inner: Codec<T>, max: number): Codec<{ T }>
	if not Types.isCodec(inner) then
		error("t.array takes a type and a maximum length, such as t.array(t.u8, 32)", 2)
	end
	if type(max) ~= "number" or max < 1 or max > 65535 or max ~= math.floor(max) then
		error("t.array(T, max): max is the longest list allowed, 1 to 65535", 2)
	end
	local prefix, writeLength, readLength = lengthWriter(max)
	local label = `array({inner.name}, {max})`
	return codec({
		name = label,
		max = prefix + max * inner.max,
		maxInstances = max * inner.maxInstances,
		write = function(w: Writer, v: any, path: string)
			if type(v) ~= "table" then
				error(`{path}: expected a list, got {describe(v)}`, 0)
			end
			local n = #v
			if n > max then
				error(`{path}: {n} items is more than {label} allows`, 0)
			end
			reserve(w, prefix)
			writeLength(w.buf, w.cursor, n)
			w.cursor += prefix
			for i = 1, n do
				inner.write(w, v[i], `{path}[{i}]`)
			end
		end,
		read = function(r: Reader): any
			need(r, prefix)
			local n = readLength(r.buf, r.cursor)
			r.cursor += prefix
			if n > max and r.strict then
				error(`{label}: {n} items is too many`, 0)
			end
			local list = table.create(n)
			for i = 1, n do
				list[i] = inner.read(r)
			end
			return list
		end,
	})
end

function Types.struct(fields: { [string]: Codec<any> }): Codec<{ [string]: any }>
	if type(fields) ~= "table" then
		error("t.struct takes a table of field = type", 2)
	end
	local names = {}
	local fixed: number? = 0
	local max, maxInstances = 0, 0
	for name, field in fields do
		if type(name) ~= "string" then
			error("t.struct: field names must be strings", 2)
		end
		if not Types.isCodec(field) then
			error(`t.struct: field {name} is not a type (did you forget to call it, as in t.string(32)?)`, 2)
		end
		table.insert(names, name)
		max += field.max
		maxInstances += field.maxInstances
		if fixed and field.fixed then
			fixed += field.fixed
		else
			fixed = nil
		end
	end
	table.sort(names)
	local count = #names
	local codecs = table.create(count)
	for i, name in names do
		codecs[i] = fields[name]
	end
	local labelParts = {}
	for i, name in names do
		labelParts[i] = `{name}: {codecs[i].name}`
	end
	return codec({
		name = `struct(\{ {table.concat(labelParts, ", ")} \})`,
		fixed = fixed,
		max = max,
		maxInstances = maxInstances,
		write = function(w: Writer, v: any, path: string)
			if type(v) ~= "table" then
				error(`{path}: expected a table, got {describe(v)}`, 0)
			end
			for key in v do
				if fields[key] == nil then
					error(`{path}: "{tostring(key)}" is not a field (fields: {table.concat(names, ", ")})`, 0)
				end
			end
			for i = 1, count do
				local name = names[i]
				codecs[i].write(w, v[name], `{path}.{name}`)
			end
		end,
		read = function(r: Reader): any
			local value = {}
			for i = 1, count do
				value[names[i]] = codecs[i].read(r)
			end
			return value
		end,
	})
end

return Types
