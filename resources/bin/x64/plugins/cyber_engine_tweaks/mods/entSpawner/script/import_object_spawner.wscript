// Imports an entitySpawner json export
// @author keanuwheeze
// @version 1.0.6

//////////////// Modify this //////////////////

const inputFilePathInRawFolder = "new_project_exported.json"

///////////////////////////////////////////////

import * as Logger from 'Logger.wscript';

const version = "1.0.6"

const DEFAULT_NODE_FLAGS = "FLAG_AllowForceStreamIn, FLAG_Building"
const DEFAULT_STREAMING_PRIORITY = 50

const header = {
  "Header": {
    "WolvenKitVersion": "8.14.1",
    "WKitJsonVersion": "0.0.9",
	"GameVersion": 2500,
    "DataType": "CR2W",
  },
  "Data": {
    "Version": 195,
    "BuildVersion": 0,
    "RootChunk": {},
    "EmbeddedFiles": []
  }
}

// Helpers

const createNewFile = (type) => {
	let file = JSON.parse(JSON.stringify(header))
    file.Data.RootChunk = JSON.parse(wkit.CreateInstanceAsJSON(type))
	return file
}

const getNewSector = () => {
	let data = createNewFile("worldStreamingSector")
	data.Data.RootChunk.nodeData.Type = "WolvenKit.RED4.Archive.Buffer.worldNodeDataBuffer, WolvenKit.RED4, Version=10.0.0.0, Culture=neutral, PublicKeyToken=null"
	data.Data.RootChunk.nodeData.Data = []
	return data
}

const getNewDeviceFile = () => {
	let data = createNewFile("gameDeviceResource")
	data.Data.RootChunk.data = { "Data": { "$type": "gameDeviceResourceData", "unk1" : [], "version": 2 } }

	return data
}

const getNewPSFile = () => {
	let data = createNewFile("gamePersistentStateDataResource")
	data.Data.RootChunk.buffer = {
		"BufferId": "0",
		"Flags": 4063232,
        "Type": "WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version=8.13.0.0, Culture=neutral, PublicKeyToken=null",
        "Data": {
          "Version": 4,
          "Sections": 6,
          "CruidIndex": 0,
          "CruidDict": {},
          "Chunks": []
        }
	}

	return data
}

const getNewBlock = () => {
	return createNewFile("worldStreamingBlock")
}

const getNewWorldNodeData = () => {
	let data = {
		"$type": "worldCompiledNodeInstanceSetupInfo",
		"dataGroup": "Base",
		"externalInplaceResourceHash": {
			"DepotPath": { "$type": "ResourcePath", "$storage": "uint64", "$value": "0" },
			"Flags": "Default"
		},
		"globalNodeId": { "$type": "worldGlobalNodeID", "hash": "0" },
		"instanceIndex": 4294967295,
		"nodeFlags": "FLAG_AllowForceStreamIn, FLAG_Building",
		"nodeIdx": "0",
		"patchedNode": { "$type": "NodeRef", "$storage": "uint64", "$value": "0" },
		"preboostStreamingRefPoint": { "$type": "Vector3", "X": 0, "Y": 0, "Z": 0 },
		"proxyMeshId": { "$type": "worldGlobalNodeID", "hash": "0" },
		"scale": { "$type": "Vector3", "X": 0, "Y": 0, "Z": 0 },
		"secondaryRefPointDistance": 0,
		"secondaryRefPointPosition": { "$type": "Vector3", "X": 0, "Y": 0, "Z": 0 },
		"streamingDistance": 0,
		"streamingPriority": "1",
		"streamingRefPoint": { "$type": "Vector3", "X": 0, "Y": 0, "Z": 0 },
		"todvisMask": "0",
		"transform": {
			"$type": "Transform",
			"orientation": { "$type": "Quaternion", "i": 0, "j": 0, "k": 0, "r": 1 },
			"position": { "$type": "Vector4", "W": 0, "X": 0, "Y": 0, "Z": 0 }
		}
	}
    return JSON.parse(JSON.stringify(data))
}

const deepCopy = (origin, target) => {
    for (let key in origin) {
        if (typeof origin[key] === 'object' && origin[key] !== null) {
            if (!target[key]) {
                target[key] = Array.isArray(origin[key]) ? [] : {};
            }
            deepCopy(origin[key], target[key]);
        } else {
            target[key] = origin[key];
        }
    }
}

function fnv1a64NodeRef(value) {
	value = value.replace(/#/g, "");

    let hash = 0xcbf29ce484222325n;
    const prime = 0x100000001b3n;

    for (let i = 0; i < value.length; i++) {
        const code = value.charCodeAt(i);
        const byte = code <= 0x7f ? code : 0x3f;
        hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * prime);
    }

    return hash;
}

const insertNode = (sector, node) => {
	let nodeData = getNewWorldNodeData()
	let streamingRefPoint = node.streamingRefPoint || node.position

	nodeData.nodeIdx = sector.Data.RootChunk.nodes.length.toString()
	
	// Position
	nodeData.transform.position.X = node.position.x
	nodeData.transform.position.Y = node.position.y
	nodeData.transform.position.Z = node.position.z
	
	// Streaming values
	nodeData.secondaryRefPointDistance = node.secondaryRange
	nodeData.streamingDistance = node.primaryRange

	// Flags and priority
	nodeData.nodeFlags = node.nodeFlags ?? DEFAULT_NODE_FLAGS
	nodeData.streamingPriority = node.streamingPriority ?? DEFAULT_STREAMING_PRIORITY

	// Streaming reference points
	nodeData.secondaryRefPointPosition.X = streamingRefPoint.x
	nodeData.secondaryRefPointPosition.Y = streamingRefPoint.y
	nodeData.secondaryRefPointPosition.Z = streamingRefPoint.z

	nodeData.streamingRefPoint.X = streamingRefPoint.x
	nodeData.streamingRefPoint.Y = streamingRefPoint.y
	nodeData.streamingRefPoint.Z = streamingRefPoint.z

	nodeData.preboostStreamingRefPoint.X = node.position.x
	nodeData.preboostStreamingRefPoint.Y = node.position.y
	nodeData.preboostStreamingRefPoint.Z = node.position.z

	// Scale
	nodeData.scale.X = node.scale.x
	nodeData.scale.Y = node.scale.y
	nodeData.scale.Z = node.scale.z
	
	// Rotation
	nodeData.transform.orientation.i = node.rotation.i
	nodeData.transform.orientation.j = node.rotation.j
	nodeData.transform.orientation.k = node.rotation.k
	nodeData.transform.orientation.r = node.rotation.r
	
	// NodeRef/global node ID
	if (node.nodeRef !== undefined && node.nodeRef !== "") {
		nodeData.globalNodeId.hash = fnv1a64NodeRef(node.nodeRef).toString()
		sector.Data.RootChunk.nodeRefs.push({
			"$type": "NodeRef",
			"$storage": "string",
			"$value": node.nodeRef
		})
	} else {
		nodeData.globalNodeId.hash = wkit.HashString(JSON.stringify(nodeData), "fnv1a64").toString()
	}

	sector.Data.RootChunk.nodeData.Data.push(nodeData)
	
	let worldNode = JSON.parse(wkit.CreateInstanceAsJSON(node.type))

	// WolvenKit 10 templates pre-create some handles (filterData, Settings) with HandleId "0", which
	// resolves to the sector's first node instead of a new object
	for (const value of Object.values(worldNode)) {
		if (value !== null && typeof value === "object" && "HandleId" in value) {
			delete value.HandleId
		}
	}

	sortInstanceData(node.data)
	deepCopy(node.data, worldNode)

	// Debug name for wkit
	worldNode.debugName.$value = node.name || ""

	sector.Data.RootChunk.nodes.push({HandleId : sector.Data.RootChunk.nodes.length.toString() , Data : worldNode})
}

const createSectorFromData = (data) => {
	let sector = getNewSector()
	sector.Data.RootChunk.category = data.category
	sector.Data.RootChunk.level = data.level
	sector.Data.RootChunk.variantIndices = [0]
	sector.Data.RootChunk.version = 68
	sector.Data.RootChunk.cookingPlatform = "PLATFORM_PC"

	if (data.variantIndices !== undefined) {
		sector.Data.RootChunk.variantIndices = data.variantIndices
	}

	return sector
}

const addSectorToBlock = (block, info, root) => {
	let descriptor = JSON.parse(wkit.CreateInstanceAsJSON("worldStreamingSectorDescriptor"))
	descriptor.category = info.category
	descriptor.level = info.level

	descriptor.numNodeRanges = 1 + (info.variants !== undefined ? info.variants.length : 0)
	
	descriptor.streamingBox.Max.X = info.max.x
	descriptor.streamingBox.Max.Y = info.max.y
	descriptor.streamingBox.Max.Z = info.max.z
	
	descriptor.streamingBox.Min.X = info.min.x
	descriptor.streamingBox.Min.Y = info.min.y
	descriptor.streamingBox.Min.Z = info.min.z
	
	descriptor.data.DepotPath.$storage = "string"
	descriptor.data.DepotPath.$value = `${root}/sectors/${info.name}.streamingsector`

	if (info.prefabRef !== undefined && info.prefabRef !== "") {
		descriptor.questPrefabNodeRef.$storage = "string"
		descriptor.questPrefabNodeRef.$value = info.prefabRef
	}

	if (info.variants !== undefined) {
		info.variants.forEach((variant) => {
			let variantData = JSON.parse(wkit.CreateInstanceAsJSON("worldStreamingSectorVariant"))

			variantData.enabledByDefault = variant.defaultOn
			variantData.name.$value = variant.name
			variantData.nodeRef.$storage = "string"
			variantData.nodeRef.$value = variant.ref
			variantData.rangeIndex = variant.index
			variantData.variantId = Math.abs(~~wkit.HashString(variant.ref + variant.name, "fnv1a32"))

			descriptor.variants.push(variantData)
		})
	}

	block.Data.RootChunk.descriptors.push(descriptor)
}

const sortInstanceData = (data) => {
	if (data["instanceData"]) {
		const instanceDataSorted = []

		for (const dataEntry of data["instanceData"]["Data"]["buffer"]["Data"]["Chunks"]) {
			if (dataEntry["id"] == undefined) {
				instanceDataSorted.push(dataEntry)
			}
		}

		for (const dictKey in data["instanceData"]["Data"]["buffer"]["Data"]["CruidDict"]) {
			for (const dataEntry of data["instanceData"]["Data"]["buffer"]["Data"]["Chunks"]) {
				if (dataEntry["id"] === data["instanceData"]["Data"]["buffer"]["Data"]["CruidDict"][dictKey]) {
					instanceDataSorted.push(dataEntry)
				}
			}
		}

		data["instanceData"]["Data"]["buffer"]["Data"]["Chunks"] = instanceDataSorted
	}
}

//TODO: Put these in a list
// BufferID - Flags - Type - Data

const reorderJSONByType = (data) => {
    if (Array.isArray(data)) {
        return data.map(reorderJSONByType)
    } else if (data !== null && typeof data === "object") {
        const reordered = {};
        const keys = Object.keys(data);

        if (keys.includes("$type")) {
            reordered["$type"] = data["$type"];
        }
		if (keys.includes("ShapeType")) {
            reordered["ShapeType"] = data["ShapeType"];
        }
        if (keys.includes("BufferId")) {
            reordered["BufferId"] = data["BufferId"];
        }
        if (keys.includes("Flags")) {
            reordered["Flags"] = data["Flags"];
        }
        if (keys.includes("Type")) {
            reordered["Type"] = data["Type"];
        }

        for (let key of keys) {
            if (key !== "$type" && key !== "ShapeType" && key !== "Type" && key !== "BufferId" && key !== "Flags") {
                reordered[key] = reorderJSONByType(data[key]);
            }
        }

        return reordered;
    } else {
        return data;
    }
}

// Main import logic
export function RunEntitySpawnerImport(filePath = inputFilePathInRawFolder, calledFromExternal = false) {
	if (!filePath) {
		Logger.Error("No file path provided!")
		return;
	}

	if (!calledFromExternal && (!filePath || !wkit.FileExistsInRaw(filePath))) {
		return;
	}

	if (!wkit.FileExistsInRaw(filePath)) {
		Logger.Error(`File ${filePath} does not exist! Make sure the file sits either in the root of the raw folder, or adjust the inputFilePathInRawFolder variable accordingly.`)
		return;
	}
	
	Logger.Success(`Starting to import ${filePath}`);
	let data = JSON.parse(wkit.LoadRawJsonFromProject(filePath, "json"))

	data = reorderJSONByType(data)

	if (data == null) {
		Logger.Error(`File ${filePath} does not exist / wrong format!`)
	} else {
		if (data.version && data.version > version) {
			Logger.Error(`File ${filePath} requires import script version ${data.version} or higher, but script version is ${version}.`)
			return
		}

		let block = getNewBlock()

		data.sectors.forEach((entry) => {
			addSectorToBlock(block, entry, data.name)
			let sector = createSectorFromData(entry)

			entry.nodes.forEach((node) => {
				insertNode(sector, node)
			})

			wkit.SaveToProject(`${data.name}/sectors/${entry.name}.streamingsector`, wkit.JsonToCR2W(JSON.stringify(sector)))
		})

		let hasDevices = data.devices !== undefined && Object.keys(data.devices).length > 0
		let hasPS = data.psEntries !== undefined && Object.keys(data.psEntries).length > 0

		if (hasDevices) {
			let devices = getNewDeviceFile()

			for (const [hash, device] of Object.entries(data.devices)) {
				devices.Data.RootChunk.data.Data.unk1.push({
					"$type": "gameDeviceResourceData_Cls1",
					"children": device.children,
					"className": {
						"$type": "CName",
						"$storage": "string",
						"$value": device.className
					},
					"hash": device.hash,
					"nodePosition": {
						"$type": "Vector3",
						"X": device.nodePosition.x,
						"Y": device.nodePosition.y,
						"Z": device.nodePosition.z
					},
					"parents": device.parents
				})
			}
			wkit.SaveToProject(`${data.name}/custom_devices.devices`, wkit.JsonToCR2W(JSON.stringify(devices)))
		}

		if (hasPS) {
			let ps = getNewPSFile()
			let index = 0
			for (const [_, entry] of Object.entries(data.psEntries)) {
				ps.Data.RootChunk.buffer.Data.Chunks.push(entry.instanceData)
				ps.Data.RootChunk.buffer.Data.CruidDict[index.toString()] = entry.PSID
				index++
			}
			wkit.SaveToProject(`${data.name}/custom_devices.psrep`, wkit.JsonToCR2W(JSON.stringify(ps)))
		}

		let xl = {
			streaming: {
				blocks: [
					`${data.name}/all.streamingblock`
				]
			}
		}

		if (hasDevices || hasPS) {
			xl.resource = {
				patch : {}
			}
		}
		if (hasDevices) {
			xl.resource.patch[`${data.name}/custom_devices.devices`] = [
				"base\\worlds\\03_night_city\\_compiled\\default\\03_night_city.devices"
			]
		}
		if (hasPS) {
			xl.resource.patch[`${data.name}/custom_devices.psrep`] = [
				"base\\worlds\\03_night_city\\_compiled\\default\\03_night_city.psrep"
			]
		}

		let xlBlob = JSON.stringify(xl)

		if (data.xlFormat == 1) {
			xlBlob = wkit.JsonToYaml(xlBlob)
		}

		wkit.SaveToResources(`${data.name}.xl`, xlBlob)
		wkit.SaveToProject(`${data.name}/all.streamingblock`, wkit.JsonToCR2W(JSON.stringify(block)))

		Logger.Success("Import finished.")
	}
}

RunEntitySpawnerImport();
