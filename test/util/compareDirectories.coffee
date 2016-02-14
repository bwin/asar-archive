
fs = require 'fs'
path = require 'path'

_ = require 'lodash'
walkdir = require 'walkdir'

module.exports = (dirA, dirB, cb) ->
	crawlFilesystem dirA, (err, pathsA, metadataA) ->
		crawlFilesystem dirB, (err, pathsB, metadataB) ->
			relativeA = _.map pathsA, (pathAItem) -> path.relative dirA, pathAItem
			relativeB = _.map pathsB, (pathBItem) -> path.relative dirB, pathBItem
			onlyInA = _.difference relativeA, relativeB
			onlyInB = _.difference relativeB, relativeA
			inBoth = _.intersection pathsA, pathsB
			differentFiles = []
			errorMsgBuilder = []
			err = null
			for i of inBoth
				filename = inBoth[i]
				typeA = metadataA[filename].type
				typeB = metadataB[filename].type
				# skip if both are directories
				continue if 'directory' is typeA and 'directory' is typeB
				# something is wrong if the types don't match up
				if typeA isnt typeB
					differentFiles.push filename
					continue
				fileContentA = fs.readFileSync path.join(dirA, filename), 'utf8'
				fileContentB = fs.readFileSync path.join(dirB, filename), 'utf8'
				differentFiles.push filename if fileContentA isnt fileContentB
			if onlyInA.length
				errorMsgBuilder.push "\tEntries only in '#{dirA}':"
				errorMsgBuilder.push "\t  #{file}" for file in onlyInA
			if onlyInB.length
				errorMsgBuilder.push "\tEntries only in '#{dirB}':"
				errorMsgBuilder.push "\t  #{file}" for file in onlyInB
			if differentFiles.length
				errorMsgBuilder.push "\tDifferent file content:"
				errorMsgBuilder.push "\t  #{file}" for file in differentFiles
			err = new Error "\n" + errorMsgBuilder.join "\n" if errorMsgBuilder.length
			cb err
			return
		return
	return

sortBy = (prop) -> (a, b) ->
	return -1 if a[prop] < b[prop]
	return 1 if a[prop] > b[prop]
	return 0

# this code is deliberately duplicated from `archive`
# so we pick up errors when modifying it there
crawlFilesystem = (dir, cb) ->
	# cb: (err, filenames[], metadata{type,stat})
	filenames = []
	metadata = {}

	walker = walkdir dir
	walker.on 'error', cb
	walker.on 'path', (p, stat) ->
		filenames.push p
		metadata[p] =
			type:
				if stat.isFile()
					'file'
				else if stat.isDirectory()
					'directory'
				else if stat.isSymbolicLink()
					'link'
			stat: stat
		return
	walker.on 'end', -> cb? null, filenames, metadata
	#walker.on 'end', ->
	#	filenames.sort sortBy 'name' # sort results to get a predictable order
	#	return cb? null, filenames, metadata
	return
