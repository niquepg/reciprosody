class UploadController < ApplicationController
	require 'shellwords'

	before_filter :user_filter, :only => [:ajx_upload, :upload_test]

	def upload_test
	end

	# POST upload handler
	# Returns JSON
	def ajx_upload	
		uid = session[:upload_token]
		fileChunk = params[:fileChunk]
		fileSize = params[:fileSize].to_i
		fileName = Shellwords.escape(params[:fileName])
		numChunks = params[:numChunks].to_i
		chunkID = params[:chunkID].to_i

		Dir.chdir Rails.root
		Dir.mkdir "upload" unless Dir.exist? "upload"

		Dir.chdir "upload"
		Dir.mkdir uid unless Dir.exists? uid

		Dir.chdir uid
		File.open("%020d.chunk" % chunkID, "wb") {|f| f.write(fileChunk.read)}

		ok = true
		errors = []

		#Signal that upload file is not ready
		session[:upload_file] = nil

		# Pick an arbitrary thread to combine files
		# We pick the last thread, since it usually finishes last
		if numChunks == chunkID+1
			baseTime = Time.now
			# Wait a maximum of 30 minutes for all chunks
			# To-do: make this dynamic: estimate max wait time as f(totalBytes)
			until numChunks == Dir.glob("*.chunk").size
				if (Time.now - baseTime)/60 > 30
					ok = false;
					errors.push("Chunks took too long to arrive")
					break;
				end
			end
	
			baseTime == Time.now
			# Wait for confirmation that all bytes were written to disk
			while true
				savedBytes = 0
				Dir.glob("*.chunk").each do |chunk|
					savedBytes += File.new(chunk).size
				end
				break if savedBytes >= fileSize
		
				# Should not take more than 10 minutes to write data
				if (Time.now - baseTime)/60 > 10
					ok = false
					errors.push("Chunks took too long to write")
					break;
				end
			end
	
			#remove all other non-chunk files
			`find . -maxdepth 1 -type f -not -name '*.chunk' -exec rm {} ';'`
	
			#`rm #{fileName}` if File.exists?(fileName)
	
			`cat *.chunk >> #{fileName}`
	
			`rm *.chunk`
	
			session[:upload_file] = Dir.pwd + "/" + fileName
		end

		render :json => {:ok => ok, :errors => errors}
	end

	def user_filter
		redirect_to '/perm' unless user_signed_in?
	end
  
end