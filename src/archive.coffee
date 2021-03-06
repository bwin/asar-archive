
fs = require 'fs'
os = require 'os'
path = require 'path'
crypto = require 'crypto'
stream = require 'stream'
zlib = require 'zlib'

walkdir = require 'walkdir'
minimatch = require 'minimatch'
mkdirp = require 'mkdirp'
queue = require 'queue-async'

uint64le = require './uint64le'

MAX_SAFE_INTEGER = 9007199254740992

sortBy = (prop) -> (a, b) ->
	return -1 if a[prop] < b[prop]
	return 1 if a[prop] > b[prop]
	return 0

module.exports = class AsarArchive
	MAGIC: 'ASARv1'
	VERSION: 1
	SIZELENGTH: 64 / 8

	constructor: (@opts={}) ->
		# default options
		@opts.minSizeToCompress ?= 256
		@opts.futureMode ?= no

		@reset()
		return

	reset: ->
		@_header =
			version: @VERSION
			files: {}
		@_headerSize = 0
		@_offset = if @opts.futureMode then @MAGIC.length else 0
		@_archiveSize = 0
		@_files = []
		@_filesInternalName = []
		@_fileNodes = []
		@_filesSize = 0
		@_archiveName = null
		@_dirty = no
		@_checksum = null
		@_legacyMode = no
		return

	_searchNode: (p, create=yes) ->
		p = p.substr 1 if p[0] in '/\\'.split '' # get rid of leading slash
		name = path.basename p
		node = @_header
		return node if p is ''
		dirs = path.dirname(p).split path.sep
		for dir in dirs
			throw new Error "#{p} not found." unless node?
			if dir isnt '.'
				node.files[dir] ?= {files:{}} if create
				node = node.files[dir]
		throw new Error "#{p} not found." unless node?
		node.files[name] ?= {} if create
		node = node.files[name]
		return node

	_readHeader: (fd) ->
		if @opts.futureMode
			@_readHeaderV1 fd
		else
			@_readHeaderV0 fd
		return

	_readHeaderV0: (fd) ->
		@_legacyMode = yes

		sizeBufSize = 16#8
		sizeBuf = new Buffer sizeBufSize
		if fs.readSync(fd, sizeBuf, 0, sizeBufSize, 0) isnt sizeBufSize
			throw new Error 'Unable to read header size (V0 format)'
		size = sizeBuf.readUInt32LE 4
		actualSize = size - 8
		headerBuf = new Buffer actualSize
		if fs.readSync(fd, headerBuf, 0, actualSize, 16) isnt actualSize
			throw new Error 'Unable to read header (V0 format)'

		try
			# remove trailing 0's (because of padding that can occur?)
			headerStr = headerBuf.toString().replace /\0+$/g, ''
			@_header = JSON.parse headerStr
		catch err
			throw new Error 'Unable to parse header (assumed old format)'
		@_headerSize = size
		return

	_readHeaderV1: (fd) ->
		magicLen = @MAGIC.length
		magicBuf = new Buffer magicLen
		if fs.readSync(fd, magicBuf, 0, magicLen, null) isnt magicLen
			throw new Error "Unable to open archive: #{@_archiveName}"
		if magicBuf.toString() isnt @MAGIC
			throw new Error 'Invalid magic number'

		headerSizeOfs = @_archiveSize - (@SIZELENGTH + 16 + @SIZELENGTH) # headerSize, checksum, archiveSize
		headerSizeBuf = new Buffer @SIZELENGTH
		if fs.readSync(fd, headerSizeBuf, 0, @SIZELENGTH, headerSizeOfs) isnt @SIZELENGTH
			throw new Error "Unable to read header size: #{@_archiveName}"
		#headerSize = readUINT64 headerSizeBuf
		headerSize = uint64le.bufferToNumber headerSizeBuf

		headerOfs = @_archiveSize - headerSize - (@SIZELENGTH + 16 + @SIZELENGTH) # headerSize, checksum, archiveSize
		headerBuf = new Buffer headerSize
		if fs.readSync(fd, headerBuf, 0, headerSize, headerOfs) isnt headerSize
			throw new Error "Unable to read header: #{@_archiveName}"

		@_offset = headerOfs

		checksumSize = 16
		checksumOfs = @_archiveSize - 16 - @SIZELENGTH # checksum, archiveSize
		@_checksum = new Buffer checksumSize
		if fs.readSync(fd, @_checksum, 0, checksumSize, checksumOfs) isnt checksumSize
			throw new Error "Unable to read checksum: #{@_archiveName}"

		try
			@_header = JSON.parse headerBuf
		catch err
			throw new Error "Unable to parse header: #{@_archiveName}"
		@_headerSize = headerSize
		return

	_writeHeader: (out, cb) ->
		if @opts.futureMode
			@_writeHeaderV1 out, cb
		else
			@_writeHeaderV0 out, cb
		return

	_writeHeaderV0: (out, cb) ->
		if @opts.prettyToc
			headerStr = JSON.stringify(@_header, null, '  ').replace /\n/g, '\n'
			headerStr = "\n#{headerStr}\n"
		else
			headerStr = JSON.stringify @_header

		@_headerSize = headerStr.length
		sizeBufSize = 16
		headerSizeBuf = new Buffer sizeBufSize
		headerSizeBuf.writeUInt32LE 0x00000004, 0
		headerSizeBuf.writeUInt32LE @_headerSize+8, 4
		headerSizeBuf.writeUInt32LE @_headerSize+4, 8
		headerSizeBuf.writeUInt32LE @_headerSize, 12
		
		out.write headerSizeBuf, -> out.write headerStr, cb
		return

	_writeHeaderV1: (out, cb) ->
		out.write @MAGIC, cb
		return

	_writeFooter: (out, cb) ->
		if @opts.futureMode
			@_writeFooterV1 out, cb
		else
			# V0 has no footer
			process.nextTick cb
		return

	_writeFooterV1: (out, cb) ->
		if @opts.prettyToc
			headerStr = JSON.stringify(@_header, null, '  ').replace /\n/g, '\n'
			headerStr = "\n#{headerStr}\n"
		else
			headerStr = JSON.stringify @_header

		@_headerSize = headerStr.length
		headerSizeBuf = uint64le.numberToBuffer @_headerSize
		
		out.write headerStr, =>
			out.write headerSizeBuf, =>
				archiveFile = fs.createReadStream @_archiveName
				md5 = crypto.createHash('md5')
				archiveFile.pipe md5
				archiveFile.on 'end', =>
				#md5.on 'finish', =>
					# is this really ok ???
					@_checksum = md5.read()
					@_archiveSize = @_offset + @_headerSize + @SIZELENGTH + 16 + @SIZELENGTH  
					if @_archiveSize > MAX_SAFE_INTEGER
						return cb? new Error "archive size can not be larger than 9PB"
					archiveSizeBuf = new Buffer @SIZELENGTH
					#writeUINT64 archiveSizeBuf, @_archiveSize
					archiveSizeBuf = uint64le.numberToBuffer @_archiveSize

					out.write @_checksum, ->
						out.write archiveSizeBuf, cb
						return
					return
				return
			return
		return

	_crawlFilesystem: (dir, pattern, cb) ->
		# cb: (err, paths=[{name, stat}, ...])
		paths = []
		walker = walkdir dir
		walker.on 'error', cb
		walker.on 'path', (p, stat) ->
			paths.push
				name: p
				stat: stat
			return
		walker.on 'end', ->
			if pattern
				matchFn = minimatch.filter pattern, matchBase: yes
				paths = paths.filter (a) ->	matchFn path.sep + path.relative dir, a.name
			paths.sort sortBy 'name' # sort results to get a predictable order
			return cb? null, paths
		return

	# opens an asar archive from disk
	#open: (archiveName, cb) ->
	openSync: (archiveName) ->
		@reset()
		@_archiveName = archiveName

		try
			@_archiveSize = fs.lstatSync(archiveName).size
			fd = fs.openSync archiveName, 'r'
			@_readHeader fd
		catch err
			throw err
		fs.closeSync fd

		if @_header.version? and @_header.version > @VERSION
			throw new Error "Unsupported asar format version: #{@_header.version} (max supported: #{@VERSION})"

		return yes

	# saves an asar archive to disk
	write: (archiveFile, opts, cb) ->
		# make opts optional
		if typeof opts is 'function'
			cb = opts
			opts = {}
		appendMode = @_archiveName is archiveFile
		@_archiveName = ''
		@_archiveName = archiveFile unless archiveFile instanceof stream

		# create output dir if necessary
		mkdirp.sync path.dirname archiveFile unless archiveFile instanceof stream

		writeFile = (filename, out, internalFilename, node, cb) =>
			@opts.onFileBegin? path.sep + internalFilename

			realSize = 0
			src = fs.createReadStream filename
			
			if @opts.compress and node.size > @opts.minSizeToCompress
				if @opts.onProgress?
					src.on 'data', (chunk) =>
						@opts.onProgress? @_filesSize, chunk.length, internalFilename
						return
				gzip = zlib.createGzip()
				gzip.on 'data', (chunk) =>
					realSize += chunk.length
					return
				gzip.on 'end', =>
					node.offset = @_offset
					#node.offset = (start = @_offset - 8 - @_headerSize).toString()
					node.csize = realSize
					@_offset += realSize
					cb()
					return
				src.pipe gzip
				gzip.pipe out, end: no
			else
				src.on 'data', (chunk) =>
					realSize += chunk.length
					@opts.onProgress? @_filesSize, chunk.length, internalFilename
					return
				src.on 'end', =>
					node.offset = @_offset
					#node.offset = (@_offset - 8 - @_headerSize).toString()
					@_offset += realSize
					cb()
					return
				src.pipe out, end: no
			return

		writeArchive = (err, cb) =>
			return cb? err if err
			q = queue 1
			for file, i in @_files
				q.defer writeFile, file, out, @_filesInternalName[i], @_fileNodes[i]
			q.awaitAll (err) =>
				return cb? err if err
				@_writeFooter out, (err) =>
					return cb err if err
					@_dirty = no
					@_files = []
					@_filesInternalName = []
					@_fileNodes = []
					@_filesSize = 0
					cb()
			return
		
		start = if appendMode then @_offset else 0
		if appendMode
			out = fs.createWriteStream archiveFile, flags: 'r+', start: start
			writeArchive null, cb
		else
			out = archiveFile
			unless archiveFile instanceof stream
				out = fs.createWriteStream archiveFile
			@_writeHeader out, (err) -> writeArchive err, cb
		return

	verify: (cb) ->
		# TODO also check file size
		endOfs = @_offset + @_headerSize + @SIZELENGTH - 1
		archiveFile = fs.createReadStream @_archiveName,
			start: 0
			end: endOfs
		md5 = crypto.createHash('md5')
		archiveFile.pipe md5
		archiveFile.on 'end', =>
			actual = md5.read().toString('hex')
			excpected = @_checksum.toString('hex')
			cb null, actual is excpected, {actual, excpected}
			return
		return

	# retrieves a list of all entries (dirs, files) in archive
	getEntries: (archiveRoot='/', pattern=null)->
		archiveRoot = archiveRoot.substr 1 if archiveRoot.length > 1 and archiveRoot[0] in '/\\'.split '' # get rid of leading slash
		files = []
		fillFilesFromHeader = (p, node) ->
			return unless node?.files?
			for f of node.files
				fullPath = path.join p, f
				files.push fullPath
				fillFilesFromHeader fullPath, node.files[f]
			return

		node = @_searchNode archiveRoot, no
		throw new Error "#{archiveRoot} not found in #{@_archiveName}" unless node?
		files.push archiveRoot if node.size
		archiveRoot = "#{path.sep}#{archiveRoot}"

		fillFilesFromHeader archiveRoot, node

		files = files.filter minimatch.filter pattern, matchBase: yes if pattern

		return files

	# shouldn't be public (but is for now because of cli -ls)
	getMetadata: (filename) ->
		node = @_searchNode filename, no
		return node

	# !!! ...
	createReadStream: (filename) ->
		node = @_searchNode filename, no
		if node.size > 0
			unless @_legacyMode
				start = node.offset
			else
				start = 8 + @_headerSize + parseInt node.offset, 10
			size = node.csize or node.size
			end = start + size - 1
			inStream = fs.createReadStream @_archiveName, start: start, end: end

			if node.csize?
				gunzip = zlib.createGunzip()
				inStream.pipe gunzip
				return gunzip

			return inStream
		else
			emptyStream = stream.Readable()
			emptyStream.push null
			return emptyStream
		
	# !!! ...
	# opts can be string or object
	# extract('dest', 'filename', cb) can be used to extract a single file
	extract: (dest, opts, cb) ->
		# make opts optional
		if typeof opts is 'function'
			cb = opts
			opts = {}
		opts = root: opts if typeof opts is 'string'
		# init default opts
		archiveRoot = opts.root or '/'
		pattern = opts.pattern
		symlinksSupported = os.platform() isnt 'win32'

		filenames = @getEntries archiveRoot, pattern
		if filenames.length is 1
			archiveRoot = path.dirname archiveRoot
		else
			mkdirp.sync dest # create destination directory

		if @opts.onProgress?
			extractSize = 0
			for filename in filenames
				extractSize += @_searchNode(filename).size or 0

		relativeTo = archiveRoot
		relativeTo = relativeTo.substr 1 if relativeTo[0] in '/\\'.split ''
		relativeTo = relativeTo[...-1] if relativeTo[-1..] in '/\\'.split ''

		writeStreamToFile = (filename, destFilename, cb) =>
			@opts.onFileBegin? destFilename
			inStream = @createReadStream filename
			if @opts.onProgress?
				inStream.on 'data', (chunk) =>
					@opts.onProgress? extractSize, chunk.length, filename

			out = fs.createWriteStream destFilename
			out.on 'finish', cb
			out.on 'error', cb

			inStream.pipe out
			return

		q = queue 1
		for filename in filenames
			destFilename = filename
			destFilename = destFilename.replace relativeTo, '' if relativeTo isnt '.'
			destFilename = path.join dest, destFilename

			node = @_searchNode filename, no
			if node.files
				q.defer mkdirp, destFilename
			else if node.link
				if symlinksSupported
					destDir = path.dirname destFilename
					mkdirp.sync destDir

					linkTo = path.join destDir, relativeTo, node.link
					linkToRel = path.relative path.dirname(destFilename), linkTo

					# try to delete output file first, because we can't overwrite a link
					try fs.unlinkSync destFilename
					fs.symlinkSync linkToRel, destFilename
				else
					console.log "Warning: extracting symlinks on windows not yet supported. Skipping #{destFilename}" if @opts.verbose
					# TODO
			else
				destDir = path.dirname destFilename
				q.defer mkdirp, destDir
				q.defer writeStreamToFile, filename, destFilename

		q.awaitAll cb
		return

	# adds a single file to archive
	# also adds parent directories (without their files)
	# if content is not set, the file is read from disk (on this.write)
	addFile: (filename, opts={}) ->
		stat = opts.stat or fs.lstatSyc filename
		relativeTo = opts.relativeTo or path.dirname filename
		
		@_dirty = yes

		# JavaScript can not precisely present integers >= MAX_SAFE_INTEGER.
		if stat.size > MAX_SAFE_INTEGER
			throw new Error "#{p}: file size can not be larger than 9PB"

		p = path.relative relativeTo, filename
		node = @_searchNode p
		node.size = stat.size
		unless @opts.futureMode
			node.offset = @_offset.toString()
			@_offset += stat.size
		
		return if node.size is 0

		@_files.push filename
		@_filesInternalName.push p
		@_fileNodes.push node
		@_filesSize += node.size
		
		if process.platform isnt 'win32' and stat.mode & 0o0100
			node.executable = true
		return

	# adds a single file to archive
	# also adds parent directories (without their files)
	addSymlink: (filename, opts={}) ->
		relativeTo = opts.relativeTo or path.dirname filename
		
		@_dirty = yes
		
		p = path.relative relativeTo, filename
		pDir = path.dirname path.join relativeTo, p
		pAbsDir = path.resolve pDir
		linkAbsolute = fs.realpathSync filename
		linkTo = path.relative pAbsDir, linkAbsolute

		node = @_searchNode p
		node.link = linkTo
		return

	# removes a file from archive
	#removeFile: (filename) ->

	# creates an empty directory in the archive
	createDirectory: (dirname) ->
		@_dirty = yes
		entry = @_searchNode dirname
		entry.files ?= {}
		return

	# adds a directory and it's files to archive
	# also adds parent directories (but without their files)
	addDirectory: (dirname, opts={}, cb=null) ->
		@_dirty = yes
		if typeof opts is 'function'
			cb = opts
			opts = {}
		relativeTo = opts.relativeTo or dirname
		@_crawlFilesystem dirname, opts?.pattern, (err, files) =>
			for file in files
				if file.stat.isDirectory()
					@createDirectory path.relative relativeTo, file.name
				else if file.stat.isFile()
					@addFile file.name,
						relativeTo: relativeTo
						stat: file.stat
				else if file.stat.isSymbolicLink()
					@addSymlink file.name, relativeTo: relativeTo
			return cb? null
		return

	# removes a directory and its files from archive
	#removeDirectory: (dirname) ->
