class ToolsController < ApplicationController
	before_filter :user_filter, :except => [:index]
	before_filter :owner_filter, 
		:only => [:edit, :update, :destroy]

	def index
		@tools = Tool.all
	end

	def manage_members
		@tool = Tool.find_by_id(params[:id])
		@memberships = @tool.tool_memberships.includes(:user)

		#-Both Formats are Used
		respond_to do |format|
		  format.html
		  format.json { render json: [@memberships] }
		end
	end

	def add_member
		@tool = Tool.find_by_id(params[:id])
		errors = []
		
		memHash = params[:member]
		if errors.length == 0 && !memHash
			errors.push("Invalid parameter format")
		end

		role = nil
		role = memHash[:role] if errors.length == 0
		
		if errors.length == 0 && ( !role || role.blank? || !(ToolMembership.roles.include?(role)) )
			errors.push("Invalid role")
		end
		
		memberEmail = nil
		if errors.length == 0 && memHash[:email] =~ /<(.+)>/
			memberEmail = $1
		end
		
		if errors.length == 0 && memberEmail == nil
			errors.push("Invalid member format #{memHash[:email]}");
		end
		
		@member = User.find_by_email(memberEmail)
		if errors.length == 0 && @member == nil
			errors.push("User does not exist")
		end
		
		
		membership = ToolMembership.where(:tool_id => @tool.id, :user_id => @member.id).first if errors.length == 0
		
		if errors.length == 0 && membership != nil
			errors.push("Membership already exists")
		end
		
		
		if errors.length == 0
			membership = ToolMembership.create(:user_id => @member.id, :tool_id => @tool.id, :role => role)
		end
			
		respond_to do |format|
			format.html { redirect_to manage_members_tool_path(@tool)}
			
			format.json do
				if(errors.length == 0)
					render :json => {:ok => true, :resp => render_to_string(:partial => 'member', :layout => false, :locals => {:mem => membership}, :formats => [:html]) }
				else
					render :json => {:ok => false, :resp => "#{errors.join("\n")}"}
				end
			end
			
		end
	end

	def remove_member
		membership = ToolMembership.find_by_id(params[:mem_id])

		respond_to do |format|
			format.json do 
				if membership
					id = membership.id
					membership.destroy
					render :json => {:ok => true, :id => id  } 
				else
					render :json => {:ok => false, :id => params[:mem_id] }
				end
			end
		end
	end

	def update_member
		membership = ToolMembership.find_by_id(params[:mem_id])
		role = params[:role]
		
		respond_to do |format|
			format.json do
				if membership && ToolMembership.roles.include?(role)
					membership.role = role
					membership.save
					render :json => {:ok => true, :id => membership.id }	
				else
					render :json => {:ok => false, :id => membership.id, :role => membership.role}
				end
			end
		end
	end



	def destroy
		@tool = Tool.find_by_id(params[:id])
		unless @tool
			redirect_to '/perm'
			return
		end
		@tool.destroy
		redirect_to '/tools'
	end

	def show
		@tool = Tool.find_by_id(params[:id])
		redirect_to '/perm' unless @tool
	end

	def new
		@tool = Tool.new
		@corpus = Corpus.find_by_id(params[:corpus_id]) if params[:corpus_id]
		session[:resumable_filename] = nil
	end

	def edit
		@tool = Tool.find_by_id(params[:id])
		redirect_to '/perm' unless @tool
		session[:resumable_filename] = nil
	end

	def update
		@tool = Tool.find_by_id(params[:id])
		redirect_to '/perm' unless @tool

		owner_text = params[:tool].delete(:owner)
		corpora_text = params[:tool].delete(:corpora)

		if !owner_text || owner_text.blank?
			@tool.errors[:owner] = " must be specified"
		end

		owner_email = ""
		if owner_text =~ /\<(.+)\>/
			owner_email = $1
		end
		@owner = User.find_by_email(owner_email);
		if !@owner
			@tool.errors[:owner] = " does not exist."  	
		end

		@corpora = corpora_from_text(corpora_text)

		respond_to do |format|
			if @tool.errors.none? && @tool.update_attributes(params[:tool]) && create_tool
				ToolMembership.where(:user_id => current_user()).destroy_all

				ToolMembership.create(
					:tool_id	=> @tool.id, 
					:user_id		=> current_user().id,
					:role			=> 'owner')

				format.html {redirect_to @tool}
				format.json do
					render :json => {:ok => true, :res => @tool.id}
				end
			else
				format.json do 
					render :json => {:ok => false, :errors => @tool.errors.to_a }
				end
			end
		end

	end

	# POST /tools
	def create
		owner_text = params[:tool].delete(:owner)
		corpora_text = params[:tool].delete(:corpora)

		@tool = Tool.new(params[:tool])

		if !owner_text || owner_text.blank?
			@tool.errors[:owner] = " must be specified"
		end

		owner_email = ""
		if owner_text =~ /\<(.+)\>/
			owner_email = $1
		end
		@owner = User.find_by_email(owner_email);
		if !@owner
			@tool.errors[:owner] = " does not exist."  	
		end

		@corpora = corpora_from_text(corpora_text)

		respond_to do |format|
			if @tool.errors.none? && @tool.save && create_tool

				ToolMembership.create(
					:tool_id	=> @tool.id, 
					:user_id		=> current_user().id,
					:role			=> 'owner')

				format.html {redirect_to @tool}
				format.json do
					render :json => {:ok => true, :res => @tool.id}
				end
			else
				format.json do 
					render :json => {:ok => false, :errors => @tool.errors.to_a}
				end
			end
		end
	end

	def download
		@tool = Tool.find_by_id(params[:id])
		unless @tool
			redirect_to '/perm'
			return
		end
		local = @tool.local
		unless local
			redirect_to '/perm'
		end
		send_file local
	end

	private

	def create_tool
		if @corpora
			ToolCorpusRelationship.where(:tool_id => @tool.id).destroy_all

			@corpora.each do |corp|
				ToolCorpusRelationship.create(
					:tool_id => @tool.id,
					:corpus_id		=> corp.id,
					:name 			=> "for");
			end
		end
		rfname = session[:resumable_filename]
		@file = rfname ? File.new(rfname) : nil
		return true unless @file

		Dir.chdir Rails.root
		path = "tools/#{@tool.id}"

		FileUtils.mkdir_p path
		FileUtils.rm_f "#{path}/*"

		extname = File.extname(@file.path)
		name = @tool.name.underscore

		path += "/#{name}#{extname}"
		File.open(path, "wb") {|f| f.write(@file.read)}

		@tool.local = path
		@tool.save

		return true
	end

	def corpora_from_text(corpora_text)
		corpora = []
		if corpora_text && !corpora_text.blank?
			corpora_text.split("\n").each do |cid|
				corp = Corpus.find_by_id(cid)
				corpora << corp if corp
			end
		end
		return corpora
	end
	#--------FILTERS--------------------------------------------------------
  	# 
  	#-----------------------------------------------------------------------

  	# Allows only users
	def user_filter
		redirect_to '/perm' unless user_signed_in?
	end

	# Allows only owners
  	# Is applied in combination with user_filter
	def owner_filter
		@tool = Tool.find_by_id(params[:id])

		#Dont filter super_key holders
		return if current_user().super_key != nil

		redirect_to '/perm' unless @tool && @tool.owners.include?(current_user())
	end

end