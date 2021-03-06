class ResumableController < ApplicationController
	require 'shellwords'
	require 'json'

	before_filter :user_filter, :except => [:resumable_test]

	FOLDER = "resumable_uploads"

	def resumable_test

	end

	def resumable_list
		@resumables = current_user.resumables
	end

	def resumable_upload_deletestate
		id = params[:id]

		if id == "all"
			ResumableIncompleteUpload.where(:user_id => current_user.id).destroy_all
			redirect_to '/resumable_list'
			return;
		end

		state = ResumableIncompleteUpload.find_by_id(id)

		unless state
			#render :json => {:ok => false}
			redirect_to '/resumable_list'
			return
		end

		state.destroy
		#render :json => {:ok => true}
		redirect_to '/resumable_list'

	end

	# GET /resumable_upload_ready
	# check to see if an upload is ready
	def resumable_upload_ready
		@resumableIdentifier = params[:identifier]
		@resumableFilename = params[:filename]
		@resumableFileSize = params[:size]

		unless @resumableFilename && @resumableFileSize
			render :json => {:ok => false, :msg => "Invalid Arguments.\nfilename = #{@resumableFilename}\ntarget_size=#{@resumableFileSize}"}
			return
		end

		@resumableFilename = Shellwords.escape(@resumableFilename)

		target_filename = getCombinedFilename()
		target_size = File.size(target_filename)

		unless File.exists?(target_filename)
			render :json => {:ok => false, :msg => "#{target_filename} does not exist"}
			return
		end

		if File.size?(target_filename) < target_size
			render :json => {:ok => false, :msg => "File is being put together. #{File.size?(target_filename)} / #{target_size}"}
			return
		end

		if File.size?(target_filename) > target_size
			render :json => {:ok => false, :msg => 'File is bigger than expected. Something has gone wrong.'}
			return
		end

		render :json => {:ok => true, :msg => "Done. Your file is ready."}

	end

	# GET /resumable_upload_clean
	# get rid of all chunks
	# upload successful
	# what remains is the put together file
	def resumable_upload_clean
		filename = params[:filename]
		identifier = params[:identifier]
		
		globstring = getChunkGlobString(identifier)
		FileUtils.rm_rf Dir.glob(globstring)

		render :json => {:filename => filename, :identifier => identifier, :globstring => globstring}
	end

	# GET /resumable_upload_abort
	# Different from clean because:
	# it also removes the combined file
	# as well as the chunks
	def resumable_upload_abort
		@resumableFilename = params[:filename]
		@resumableIdentifier = params[:identifier]
		
		globstring = getAllGlobString
		FileUtils.rm_rf Dir.glob(globstring)

		# Forget it ever happened
		session[:resumable_filename] = nil

		# echo parameters
		render :json => {:filename => @resumableFilename, :identifier => @resumableIdentifier, :globstring => globstring}
	end

	# GET /resumable_upload_savestate
	def resumable_upload_savestate
		filename = params[:filename]
		url = params[:url]
		formdata = params[:formdata]
		identifier = params[:identifier]

		filename.gsub!(/^[\.,\\,\/]*/, "");

		logger.info "**RESUMABLE::SAVING STATE** filename=#{filename} ident=#{identifier}"
		logger.info "URL = #{url}"
		logger.info "formdata = #{formdata}"



		ResumableIncompleteUpload.where(:identifier => identifier).delete_all if identifier && !identifier.blank?

		ResumableIncompleteUpload.create(:user_id => current_user().id, :filename => filename,
										 :identifier => identifier, :formdata => formdata, :url => url);

		# Only keep 20 Save-States
		ResumableIncompleteUpload.where(:user_id => current_user().id).order("created_at DESC").each_with_index do |e, i| 
			e.destroy() if i >= 20 
		end
		
		render :json => {
			:filename => filename, 
			:identifier => identifier, 
			:user_id => current_user().id, 
			:formdata => formdata, 
			:url => url
		}
	end

	# GET /resumable_upload_combine
	def resumable_upload_combine
		files = params[:files].to_i

		filename_list = JSON.parse(params[:filename_list])
		identifier_list = JSON.parse(params[:identifier_list])
		numChunks_list = JSON.parse(params[:numChunks_list])

		unless filename_list && identifier_list && numChunks_list
			render :json => {:ok => false, :msg => "Invalid Arguments.\nfilename_list = #{filename_list}\nidentifier_list = #{identifier_list}\nnumChunks_list = #{numChunks_list}"}
			return
		end

		# render :json => {:ok => true, :msg => "TESTING\nfiles = #{files}\nfilename_list = #{filename_list}\nidentifier_list = #{identifier_list}\nnumChunks_list = #{numChunks_list}"}
		# return;

		logger.info ("****FILENAME_LIST = #{filename_list}")

		filepath_list = []
		(0...files).each do |n|
			logger.info "****FILE NUMBER #{n}\t#{filename_list[n]}"

			@resumableFilename = "#{Shellwords.escape(filename_list[n])}"
			@resumableIdentifier = identifier_list[n]
			@numberOfChunks = numChunks_list[n].to_i

			unless File.exists?(@resumableFilename)
				logger.info "****COMBINING #{@resumableFilename}"
				filepath_list << combine_chunks!
			else
				filepath_list << nil
			end
		end
		
		session[:resumable_filenames] = filename_list
		session[:resumable_filepaths] = filepath_list

		render :json => {:ok => true, :msg => "Combining Chunks"}
	end


	# POST /upload 
	# Used with Resumable.js
	# Used to Upload stuff
	def post_resumable_upload
		@resumableChunkNumber = params['resumableChunkNumber'].to_i
		@resumableChunkSize = params['resumableChunkSize'].to_i
		@resumableCurrentChunkSize = params['resumableCurrentChunkSize'].to_i
		@resumableTotalSize = params['resumableTotalSize'].to_i
		@resumableIdentifier = params['resumableIdentifier']
		@resumableFilename = params['resumableFilename']
		@resumableRelativePath = params['resumableRelativePath']
		@resumableFile = params['file']
		@resumableFileSize = @resumableFile.size
		@numberOfChunks = [1, @resumableTotalSize/@resumableChunkSize].max

		# render :json => {:fileSize => @resumableFileSize}

		unless @resumableFile
			render :text => 'invalid_resumable_request'
			return
		end

		validation = validateRequest()

		unless validation == :valid
			render :text => validation
			return
		end

		chunkFileName = getChunkFilename(@resumableIdentifier, @resumableChunkNumber)

		Dir.chdir Rails.root
		Dir.mkdir "./#{FOLDER}" unless Dir.exists?("./#{FOLDER}")

		# Write file to FOLDER
		File.open(chunkFileName, "wb") {|f| f.write(@resumableFile.read) }

		if(all_chunks_here?)
			logger.info "***ALL CHUNKS HERE***"
			# combine_chunks! #Combine chunks is now called from the client-side
			logger.info("***DONE***")
			render :json => {}
		else
			logger.info("***partly done***")
			render :json => {}
		end

	end

	# GET /upload
	# Used with Resumable.js
	# Used to Test Chunks
	def get_resumable_upload
		@resumableChunkNumber = params['resumableChunkNumber'].to_i
		@resumableChunkSize = params['resumableChunkSize'].to_i
		@resumableCurrentChunkSize = params['resumableCurrentChunkSize'].to_i
		@resumableTotalSize = params['resumableTotalSize'].to_i
		@resumableIdentifier = params['resumableIdentifier']
		@resumableFilename = params['resumableFilename']
		@resumableRelativePath = params['resumableRelativePath']
		@resumableFile = nil
		@resumableFileSize = nil 
		@numberOfChunks = [1, @resumableTotalSize/@resumableChunkSize].max

		# We don't care about the file chunk itself
		# when testing to see if it exists server-side

		if(validateRequest() == :valid)
			if(File.exists?(getChunkFilename(@resumableIdentifier, @resumableChunkNumber)))
				render :text => "found", :status => 200
			else
				render :text => "not_found", :status => 404
			end
		else
			render :text => "not_found", :status => 404
		end
	end

	private

	#---------Helpers----------------------------------------------
	def all_chunks_here?
		total = 0;
		(1..@numberOfChunks).each do |chunkID|
			chunkPath = getChunkFilename(@resumableIdentifier, chunkID)
			return false unless File.exists?(chunkPath)
			chunk_size = File.size?(chunkPath)
			total += (chunk_size) ? chunk_size : 0
		end
		return false unless total == @resumableTotalSize
		return true
	end

	def combine_chunks!
		files = (1..@numberOfChunks).map {|cid| getChunkFilename(@resumableIdentifier, cid)}
		output_filename = getCombinedFilename()
		resumable_globstring = getChunkGlobString(@resumableIdentifier)
		cmd = "cat #{resumable_globstring} > #{output_filename}"
		logger.info("***#{cmd}")
		`#{cmd}`

		# Let this continue to hold the last file combined 
		# so that we don't have to change corpora, publication, and tools controllers
		session[:resumable_filename] = output_filename
		session[:resumable_original_filename] = @resumableFilename

		return output_filename
	end

	def cleanFilename(name)
		name.gsub(/[\&,\>,\<\s]/, '')
	end

	def getCombinedFilename
		logger.info("ORIGINAL_FILENAME = #{@resumableFilename}")
		"#{FOLDER}/resumable-#{@resumableIdentifier}-#{cleanFilename(@resumableFilename)}"
	end

	# get the globstring
	# for every resumable item for the current identifier
	def getAllGlobString
		cleanIdentifier!(@resumableIdentifier)
		"#{FOLDER}/resumable-#{@resumableIdentifier}*"
	end

	def validateRequest()
		cleanIdentifier!(@resumableIdentifier)

		# Check if request is sane
		return :non_resumable_request if
			@resumableChunkNumber <= 0 ||
			@resumableChunkSize <= 0 ||
			@resumableTotalSize <= 0 ||
			@resumableIdentifier == nil || @resumableIdentifier.length <= 0 ||
			@resumableFilename == nil || @resumableFilename.length <= 0;

		return :invalid_chunk_number if(@resumableChunkNumber > @numberOfChunks)

		# We don't have an upper limit on the file size

		# Different set of tests for when validateRequest()
		# is called from post_resumable_upload
		if(@resumableFileSize != nil) 
			if(@resumableChunkNumber<@numberOfChunks && @resumableFileSize!=@resumableChunkSize)
				# the chunk is not the last chunk but the chunk is not the correct size
				return :invalid_chunk_size
			end

			if (@resumableChunkNumber>1 && @resumableChunkNumber==@numberOfChunks && 
				@resumableFileSize != ((@resumableTotalSize % @resumableChunkSize) + @resumableChunkSize))

				# the last chunk should be the size of what's left modulo chunkSize
				# plus the size of a normal chunk
				# but it's not

				return :invalid_chunk_remainder
			end

			if(@numberOfChunks == 1 && @resumableFileSize != @resumableTotalSize)
				# there's only one chunk but it's not the right size
				return :invalid_single_chunk_size
			end
		end

		return :valid

	end

	def cleanIdentifier!(identifier)
		identifier.gsub!(/[^0-9A-Za-z_-]/, "")
	end

	def getChunkFilename(identifier, chunkNumber)
		cleanIdentifier!(identifier)
		return "#{FOLDER}/resumable-#{identifier}.%020d" % chunkNumber
	end

	def getChunkGlobString(identifier)
		cleanIdentifier!(identifier)
		return "#{FOLDER}/resumable-#{identifier}.*"
	end


	#---Filters--
	def user_filter
		redirect_to '/perm' unless user_signed_in?
	end
end
