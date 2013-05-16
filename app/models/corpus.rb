class Corpus < ActiveRecord::Base
	acts_as_commentable

	attr_accessible :description, :language, :name, :upload, :duration, :num_speakers, :speaker_desc, :genre, :annotation, :license, :citation, :hours, :minutes, :seconds

	has_many :users, :through => :memberships
	has_many :memberships, :dependent => :delete_all #cascading delete

	has_many :publications, :through => :publication_corpus_relationships
	has_many :publication_corpus_relationships, :dependent => :delete_all

	has_many :tools, :through => :tool_corpus_relationships
	has_many :tool_corpus_relationships, :dependent => :delete_all

	has_many :comments, :as => :commentable, :order => 'updated_at DESC'

	
	before_validation :set_duration
	before_create :assign_unique_token
	after_create :create_dirs
	before_destroy :remove_dirs

	#-----Validations--------------------------------------
	validates :name, :presence => true
	validates :language, :presence => true
	validates :num_speakers, :inclusion => 1..9999
	validates :duration, :inclusion => {:in => 1..86399, :message => "must be at least 1 second and less than 24 hours"}, :if => :times_in_correct_format
	#------------------------------------------------------
	
	attr_accessor :upload_file, :hours, :minutes, :seconds


	after_find :set_times

	def ac_small_format
		"#{self.name}<#{self.id}>"
	end

	#---Static Methods  -----------------------------------
	def self.corpora_folder
		"corpora"
	end

	def self.tmp_subFolder
		"tmp"
	end
	
	def self.archives_subFolder
		"archives"
	end
	
	def self.head_subFolder
		"head"
	end
	
	def self.svn_subFolder
		"svn"
	end

	def self.download_stage_subFolder
		"download_stage"
	end

	# AKA "Fake SVN Head"
	def self.upload_stage_subFolder
		"upload_stage"
	end
	
	#------------------------------------------------------
	# Non-Static Helpers
	#------------------------------------------------------

	# returns the svn revision number
	def svn_revisions
		infotext = `svn info #{self.svn_file_url}`
		logger.info infotext
		logger.info infotext[/^Revision:\s*(\d+)/]
		return $1.to_i if $1
		return 0
	end

	def svn_last_changed_date(version = nil)
		infotext = `svn info #{self.svn_file_url} #{"-r " if version} #{version if version}`
		logger.info infotext
		logger.info infotext[/^Last Changed Date:\s*([^\n]+)/]
		return Time.parse($1) if $1
		return ""
	end

	def svn_log(version = nil)
		return `svn log #{self.svn_file_url}` unless version
		return `svn log #{self.svn_file_url} -r #{version}`.gsub("-"*72, "");
	end

	def svn_log_array()
		revisions = self.svn_revisions
		log_array = []
		revisions.downto(1) do |r|
			log_array << self.svn_log(r)
		end
		return log_array
	end

	def svn_commits_array()
		log_array = self.svn_log_array()
		commits = []
		log_array.each do |e|
			e = e.gsub(/\| \d+ line$/, "")
			version = 0
			if e =~ /^\s*r(\d+)/
				version = $1
			end
			next if !version || version == 0

			e = e.gsub(/^\s*r(\d+) \| [^\|]+? \| /, "")	

			if e =~ /(\*\*PRE\-COMMIT STATUS\*\*\n)(.+)$/m
				status_changes = [];
				$2.split("\n").each do |line|
					(status, file) = line.split(" "); 
					status_changes << "<div class='svn_file_status'><span class='label label-invert'>#{status}</span>&nbsp;<span class=''>#{file}</span></div>"
				end

				(status, file) = $2.split(" ");
				e.gsub!("#{$1}#{$2}", "<div class='svn_status_toggle btn btn-small'>Changes</div><div class='svn_status monospace'>#{status_changes.join(' ')}</div>")
			end

			arr = e.split("\n")

			#logger.info("***ARR = #{arr}")
			next if arr.length == 0

			dateString = arr[0];
			msg = arr[2..-1].join("<br/>")

			
			msg = msg.split("<br/>")
			
			name = ""
			if(msg.shift =~ /User Name: (.+)$/)
				name = $1
			end
			
			email = ""
			if(msg.shift =~ /User Email: (.+)$/)
				email = $1
			end
			
			#logger.info ("***MSG = #{msg}")

			msg = msg.join("<br/>")
			
			commits << {:version => version, :dateString => dateString, :msg => msg, :name => name, :email => email}
			
		end
		return commits
	end

	def safe_name
		sn = self.name.downcase.gsub(/\s+/, '_');
		sn.gsub!(/[;<>\*\|`&\$!#\(\)\[\]\{\}:'"]/, '');
		return sn;
	end

	def svn_prepare_version_for_download(version = self.svn_revisions)
		Dir.chdir Rails.root
		return if self.get_archive(version)
		
		Dir.mkdir(self.download_stage_path) unless Dir.exists?(self.download_stage_path)

		uuid = SecureRandom.uuid
		tmp_dir = self.download_stage_path + "/" + uuid

		Dir.mkdir(tmp_dir)

		`svn checkout -r #{version} #{self.svn_file_url} #{tmp_dir}`

		Dir.chdir tmp_dir
		`zip -r ../../#{Corpus.archives_subFolder}/#{self.safe_name}.#{version}.zip *`
		Dir.chdir Rails.root

		FileUtils.rm_rf(tmp_dir)
	end

	def get_archive(version)
		archive = nil
		Dir.glob(self.archives_path + "/*").each do |file|
			if file =~ /#{version}\.\w+$/
				archive = file
			end
		end
		return archive
	end

	# Creates a fake hard-linked head
	def prepare_upload_stage
		Dir.chdir Rails.root
		FileUtils.rm_rf self.upload_stage_path if Dir.exists? self.upload_stage_path
		`cp -al #{self.head_path} #{self.upload_stage_path}`
		`rm -rf #{self.upload_stage_path}/.svn`
		`cp -r #{self.head_path}/.svn #{self.upload_stage_path}/.svn`
	end

	def rsync_tmp_and_upload_stage
		`rsync -ar #{self.tmp_path}/ #{self.upload_stage_path}/`
	end

	def remove_upload_stage
		Dir.chdir Rails.root
		FileUtils.rm_rf self.upload_stage_path if Dir.exists? self.upload_stage_path
	end

	#-----PATH HELPERS-------------------------------------
	def home_path
		if self.utoken == nil
			assign_unique_token
			create_dirs
		end
		Corpus.corpora_folder  + "/" + self.utoken
	end
	
	def archives_path
		home_path + "/" + Corpus.archives_subFolder
	end

	def download_stage_path
		home_path + "/" + Corpus.download_stage_subFolder
	end

	def upload_stage_path
		home_path + "/" + Corpus.upload_stage_subFolder
	end
	
	def tmp_path
		home_path + "/" + Corpus.tmp_subFolder
	end
	
	def svn_path
		home_path + "/" + Corpus.svn_subFolder
	end
	
	def head_path
		home_path + "/" + Corpus.head_subFolder
	end
	
	def svn_file_url
		"file://#{Rails.root}/#{self.svn_path}"
	end
	
	#-------------------------------------------------------

	#------------------Rights-------------------------------
	# Not exactly the same as memberships
	#-------------------------------------------------------
	def canEdit?(user)
		return false unless user
		return true if self.owners.include? user
		return true if user.super_key != nil
		return false
	end
	
	#-------------------memberships-------------------------
	accepts_nested_attributes_for :memberships, :users

	scope :owner_of,	where(memberships: {role: 'owner'})
	scope :approver_of,	where(memberships: {role: 'approver'})
	scope :member_of, 	where(memberships: {role: 'member'})


	def owners
		self.users.owners.all
	end

	def approvers
		self.users.approvers.all
	end

	def members
		self.users.members.all
	end
	#--------------------------------------------------------

	#--Attribute_writer for @upload_file
	def upload=(upload_file)
		@upload_file = upload_file
	end

	#--Removes associated directories
	def remove_dirs
		return unless self.utoken
		FileUtils.rm_rf(self.home_path) if Dir.exists? self.home_path;
	end
	
	def create_dirs
		Dir.chdir Rails.root
		return if Dir.exists? self.home_path

		Dir.mkdir self.home_path 
		sub_dir = []
		
		sub_dir << self.archives_path;
		sub_dir << self.tmp_path;
		sub_dir << self.head_path;
		sub_dir << self.svn_path;
		sub_dir << self.download_stage_path;
	
		sub_dir.each do |d|
			Dir.mkdir d unless Dir.exists? d
		end

		logger.info "svnadmin create #{self.svn_path}"
		`svnadmin create #{self.svn_path}`

		`svn co #{self.svn_file_url} #{self.head_path}`
	end

	#--Returns human-readable duration
	def human_duration
		Time.at(self.duration).gmtime.strftime('%R:%S')
	end

	#--Times format validator function--
	def times_in_correct_format
		hours   = if @hours.nil?    then 0 else @hours.to_i end
		minutes = if @minutes.nil?  then 0 else @minutes.to_i end
		seconds = if @seconds.nil?  then 0 else @seconds.to_i end

		hours, minutes, seconds = Corpus.normalize_time(hours, minutes, seconds)


		if hours < 0 || hours > 23 then
			errors.add(:hours, "Must be between 0 and 23")
			return false
		end
		if minutes < 0 || minutes > 59 then
			errors.add(:minutes, "must be between 0 and 59")
			return false
		end
		if seconds < 0 || seconds > 59 then
			errors.add(:seconds, "must be between 0 and 59")
			return false
		end
		return true
	end

	def self.normalize_time(hours, minutes, seconds) 
		base = hours * 3600 + minutes * 60 + seconds
		minutes = base / 60;
		base -= minutes * 60;

		hours = minutes / 60;
		minutes -= hours * 60;

		seconds = base
		return hours, minutes, seconds
	end

	#Sets hours, minutes, seconds
	def set_times
		seconds = self.duration
		@hours    = seconds/3600; seconds %= 3600
		@minutes  = seconds/60; seconds %= 60
		@seconds  = seconds
	end
	#--Sets duration from virtual attributes--
	def set_duration
		@hours    = 0 if @hours.nil? || @hours.to_i < 0
		@minutes  = 0 if @minutes.nil? || @minutes.to_i < 0
		@seconds  = 0 if @seconds.nil? || @seconds.to_i < 0
		self.duration = @hours.to_i()*3600 + @minutes.to_i()*60 + @seconds.to_i()
	end

	def assign_unique_token
		self.utoken = gen_unique_token() unless self.utoken
	end

	private

	def gen_unique_token
		utoken = ""
		begin
			utoken = SecureRandom.uuid
		end while Corpus.where(:utoken => utoken).exists?
		return utoken
	end

end
