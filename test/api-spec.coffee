
assert = require 'assert'
fs = require 'fs'
os = require 'os'

streamEqual = require 'stream-equal'

asar = require '../src/asar'
compDirs = require './util/compareDirectories'
compFiles = require './util/compareFiles'

fixOsInconsistencies = (str) ->
	if os.platform() is 'win32'
		# convert to unix ~~line endings and~~ path delimiters
		str
		#.replace /\r\n/g, '\n'
		.replace /\//g, '\\'
	else
		str

#asar.opts.verbose = yes

describe 'asar API ->', ->
	@timeout 1000*60 * 1 # minutes

	describe 'handle archive ->', ->
		archiveFilename = 'test/input/extractthis.asar'
		it 'should list dirs&files in archive', ->
			archive = asar.loadArchive archiveFilename
			actual = archive.getEntries().join os.EOL
			expected = fs.readFileSync 'test/expected/extractthis-filelist.txt', 'utf8'
			expected = fixOsInconsistencies expected
			assert.equal actual, expected

		it 'should list dirs&files for directory in archive', ->
			archive = asar.loadArchive archiveFilename
			actual = archive.getEntries('dir2').join os.EOL
			expected = fs.readFileSync 'test/expected/extractthis-filelist-dir2.txt', 'utf8'
			expected = fixOsInconsistencies expected
			assert.equal actual, expected

		it 'should list dirs&files in archive with pattern', ->
			archive = asar.loadArchive archiveFilename
			actual = archive.getEntries('/', '*.txt').join os.EOL
			expected = fs.readFileSync 'test/expected/extractthis-filelist-txt-only.txt', 'utf8'
			expected = fixOsInconsistencies expected
			assert.equal actual, expected

		it 'should list dirs&files for directory in archive with pattern', ->
				archive = asar.loadArchive archiveFilename
				actual = archive.getEntries('dir2', '*.txt').join os.EOL
				expected = fs.readFileSync 'test/expected/extractthis-filelist-dir2-txt-only.txt', 'utf8'
				expected = fixOsInconsistencies expected
				assert.equal actual, expected

		it 'should stream a text file from archive', (done) ->
			actual = asar.createReadStream archiveFilename, 'dir1/file1.txt'
			expected = fs.createReadStream 'test/expected/extractthis/dir1/file1.txt', 'utf8'
			streamEqual actual, expected, (err, equal) ->
				done assert.ok equal

		it 'should stream a binary file from archive', (done) ->
			actual = asar.createReadStream archiveFilename, 'dir2/file2.png'
			expected = fs.createReadStream 'test/expected/extractthis/dir2/file2.png', 'utf8'
			streamEqual actual, expected, (err, equal) ->
				done assert.ok equal

		it 'should extract an archive', (done) ->
			extractTo = 'tmp/extractthis-api/'
			asar.extractArchive archiveFilename, extractTo, (err) ->
				compDirs extractTo, 'test/expected/extractthis', done

		it 'should extract a directory from archive', (done) ->
			extractTo = 'tmp/extractthis-dir2-api/'
			asar.extractArchive archiveFilename, extractTo, root: 'dir2', (err) ->
				compDirs extractTo, 'test/expected/extractthis-dir2', done

		it 'should extract a file from archive', (done) ->
			filename = 'file1.txt'
			filepath = "dir1/#{filename}"
			extractTo = 'tmp/extractthis-single-file/'
			asar.extractArchive archiveFilename, extractTo, filepath, (err) ->
				done compFiles "#{extractTo}#{filename}", "test/expected/extractthis/#{filepath}"

		#it 'should extract from archive with pattern', (done) -> done new Error 'test not implemented'
		#it 'should extract a directory from archive with pattern', (done) -> done new Error 'test not implemented'

	#	it 'should verify an archive', (done) ->
	#		asar.verifyArchive 'test/input/extractthis.asar', (err, ok) ->
	#			done assert.ok ok
	#
		#it 'should append a directory to archive', (done) ->
		#	appendDir = 'test/input/addthis'
		#	archiveName = 'tmp/packthis-api.asar'
		#	archive = asar.loadArchive archiveName
		#	archive.addDirectory appendDir, (err) ->
		#		return done err if err
		#		archive.write archiveName, ->
		#			done compFiles archiveName, 'test/expected/packthis-appended.asar'

	describe 'create and handle archive ->', ->
		archiveFilename = 'tmp/packthis-api.asar'
		it 'should create archive from directory', (done) ->
			asar.createArchive 'test/input/packthis/', archiveFilename, (err) ->
				done compFiles archiveFilename, 'test/expected/packthis.asar'
		it 'should extract created archive', (done) ->
				extractTo = 'tmp/packthis-extracted-api/'
				asar.extractArchive archiveFilename, extractTo, (err) ->
					compDirs extractTo, 'test/input/packthis/', done

	describe 'archive our own dependencies ->', ->
		src = 'node_modules/'
		archiveFilename = 'tmp/modules-api.asar'
		extractTo = 'tmp/modules-api/'

		it 'create archive', (done) ->
			asar.createArchive src, archiveFilename, (err) ->
				return done err
		
		it 'extract archive', (done) ->
			asar.extractArchive archiveFilename, extractTo, done

		it 'compare', (done) ->
			compDirs extractTo, src, done

		it 'extract coffee-script', (done) ->#
			asar.extractArchive archiveFilename, 'tmp/coffee-script-api/', root: 'coffee-script/', done

		it 'compare coffee-script', (done) ->
			compDirs 'tmp/coffee-script-api/', 'node_modules/coffee-script/', done
