// Converts the project's 2.31 streaming sectors (version 62) to the 2.5 format (version 68)
// Requires WolvenKit 10 or newer
// @author Akiway
// @version 1.0.0

//////////////// Modify this //////////////////

// Sector paths relative to the project's archive folder. Empty: every .streamingsector of the project.
// Separate folders with / or \\ ("my_mod/sectors/a.streamingsector"); a single \ is swallowed by JavaScript.
const sectorPaths = []
// Saves each original sector as JSON under raw\sector_backup_2.31\ before overwriting it.
const backupToRaw = true

///////////////////////////////////////////////

import * as Logger from 'Logger.wscript';

const VERSION_2_31 = 62
const VERSION_2_5 = 68
const NO_INSTANCE = 4294967295

// ENodeFlags, bit 0 first.
const NODE_FLAGS = [
	"FLAG_BoostedToPrefabDistance", "FLAG_AllowForceStreamIn", "FLAG_IsInterior", "FLAG_NoCollision",
	"FLAG_Quest", "FLAG_PrefabProxyMesh", "FLAG_Building", "FLAG_Decoration", "FLAG_Road", "FLAG_Terrain",
	"FLAG_VisualFluff", "FLAG_IsExludedOnConsole", "FLAG_2DCheck", "FLAG_Culling_IsCullable",
	"FLAG_Culling_IsForceCulledAlways", "FLAG_Culling_IsForceCulledNearPeripheral",
	"FLAG_Culling_IsAdvertisementBillboardEntity", "FLAG_GlobalIllumination", "FLAG_FallbackDrop",
	"FLAG_AllowDistanceBoosting", "FLAG_IsExludedOnNextGenConsoles"
]

// Helpers

const floatView = new DataView(new ArrayBuffer(4))

const floatToBits = (value) => {
	floatView.setFloat32(0, value, true)
	return BigInt(floatView.getUint32(0, true))
}

const bitsToFloat = (bits) => {
	floatView.setUint32(0, Number(bits & 0xFFFFFFFFn), true)
	return floatView.getFloat32(0, true)
}

// WolvenKit names record fields after their RED names; matched without case.
const findKey = (record, name) => Object.keys(record).find(key => key.toLowerCase() === name.toLowerCase())

const readField = (record, name) => {
	const key = findKey(record, name)
	if (key === undefined) {
		throw new Error(`record has no "${name}" field`)
	}
	return record[key]
}

const readUInt = (record, name) => BigInt(String(readField(record, name)))

const readFloat = (record, name) => {
	const value = Number(readField(record, name))
	if (Number.isNaN(value)) {
		throw new Error(`"${name}" is NaN, its bits cannot be recovered`)
	}
	return value
}

const readFlags = (record, name) => {
	const value = readField(record, name)
	if (typeof value === "number") {
		return BigInt(value)
	}

	let bits = 0n
	for (const token of String(value).split(/[,|]/)) {
		const flag = token.trim()
		if (flag === "" || flag === "FLAG_None") {
			continue
		}

		const index = NODE_FLAGS.indexOf(flag)
		if (index >= 0) {
			bits |= 1n << BigInt(index)
		} else if (/^\d+$/.test(flag)) {
			bits |= BigInt(flag)
		} else {
			throw new Error(`unknown node flag "${flag}"`)
		}
	}
	return bits
}

// Keeps the JSON type WolvenKit used for the field: string for 64-bit values, number otherwise.
const writeUInt = (record, name, value) => {
	const key = findKey(record, name) ?? name
	record[key] = typeof record[key] === "string" ? value.toString() : Number(value)
}

const writeFlags = (record, name, bits) => {
	const names = NODE_FLAGS.filter((_, index) => (bits >> BigInt(index)) & 1n)
	record[findKey(record, name) ?? name] = names.length > 0 ? names.join(", ") : "FLAG_None"
}

// WolvenKit 10 reads every record in the 2.5 layout, so a 2.31 record arrives with its bytes reinterpreted.
// The 2.31 tail is rebuilt from those fields, then converted the way the game converts version 62.
const convertRecord = (record, nodeCount) => {
	const bits112 = readUInt(record, "nodeIdx")
		| (readFlags(record, "nodeFlags") << 19n)
		| (readUInt(record, "streamingPriority") << 40n)
		| (readUInt(record, "todvisMask") << 48n)
	const oldBits = floatToBits(readFloat(record, "secondaryRefPointDistance"))
		| (floatToBits(readFloat(record, "streamingDistance")) << 32n)
	const oldTodvis = readUInt(record, "instanceIndex") & 0xFFFFn

	const nodeIndex = oldBits & 0x7FFFFn
	if (nodeIndex >= BigInt(nodeCount)) {
		throw new Error(`node index ${nodeIndex} is out of range (${nodeCount} nodes)`)
	}

	const secondaryDistance = bitsToFloat(bits112 & 0xFFFFFFFFn)
	const streamingDistance = bitsToFloat(bits112 >> 32n)
	if (Number.isNaN(secondaryDistance) || Number.isNaN(streamingDistance)) {
		throw new Error("a streaming distance is NaN")
	}

	const newBits = nodeIndex | ((oldBits >> 1n) & 0xFFFFFFF80000n) | (oldTodvis << 48n)
	writeUInt(record, "nodeIdx", newBits & 0x7FFFFn)
	writeFlags(record, "nodeFlags", (newBits >> 19n) & 0x1FFFFFn)
	writeUInt(record, "streamingPriority", (newBits >> 40n) & 0xFFn)
	writeUInt(record, "todvisMask", (newBits >> 48n) & 0xFFFFn)
	record[findKey(record, "secondaryRefPointDistance")] = secondaryDistance
	record[findKey(record, "streamingDistance")] = streamingDistance
	writeUInt(record, "instanceIndex", BigInt(NO_INSTANCE))

	const groupKey = findKey(record, "dataGroup") ?? "dataGroup"
	record[groupKey] = typeof record[groupKey] === "number" ? 0 : "Base"
}

const convertSector = (path) => {
	const json = wkit.GetFileFromProject(path, OpenAs.Json)
	if (!json) {
		Logger.Error(`${path}: could not be read, see the error above. WolvenKit 10 cannot read 2.31 records whose data group is EP1.`)
		return false
	}

	const file = JSON.parse(json)
	const sector = file.Data.RootChunk
	if (sector["$type"] !== "worldStreamingSector") {
		Logger.Warning(`${path}: not a streaming sector, skipped.`)
		return false
	}
	if (sector.version === VERSION_2_5) {
		Logger.Info(`${path}: already in the 2.5 format.`)
		return false
	}
	if (sector.version !== VERSION_2_31) {
		Logger.Error(`${path}: unknown sector version ${sector.version}.`)
		return false
	}

	const records = sector.nodeData && sector.nodeData.Data
	if (!Array.isArray(records)) {
		Logger.Error(`${path}: the nodeData buffer could not be read.`)
		return false
	}
	if (records.length > 0 && findKey(records[0], "MaxStreamingDistance") !== undefined) {
		Logger.Error(`${path}: records use the 2.31 field names. Run this script with WolvenKit 10 or newer.`)
		return false
	}

	try {
		records.forEach(record => convertRecord(record, sector.nodes.length))
	} catch (error) {
		Logger.Error(`${path}: ${error.message}. Nothing was written.`)
		return false
	}

	sector.version = VERSION_2_5

	if (backupToRaw) {
		wkit.SaveToRaw(`sector_backup_2.31\\${path}.json`, json)
	}
	wkit.SaveToProject(path, wkit.JsonToCR2W(JSON.stringify(file)))
	Logger.Success(`${path}: converted ${records.length} records.`)
	return true
}

// Main

const run = () => {
	// GetProjectFiles returns a .NET list, which some WolvenKit builds expose without array methods.
	const projectFiles = []
	for (const path of wkit.GetProjectFiles("archive")) {
		projectFiles.push(path)
	}

	const paths = sectorPaths.length > 0
		? sectorPaths.map(path => path.replace(/\//g, "\\"))
		: projectFiles.filter(path => path.toLowerCase().endsWith(".streamingsector"))

	if (paths.length === 0) {
		Logger.Warning("No streaming sector found in the project.")
		return
	}

	const known = new Set(projectFiles.map(path => path.toLowerCase()))
	let converted = 0
	for (const path of paths) {
		if (!known.has(path.toLowerCase())) {
			Logger.Error(`${path}: not found in the project's archive folder.`)
		} else if (convertSector(path)) {
			converted++
		}
	}

	Logger.Info(`${converted} of ${paths.length} sector(s) converted to the 2.5 format.`)
}

run()
