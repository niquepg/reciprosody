class Corpus < ActiveRecord::Base
  attr_accessible :description, :language, :name, :upload, :duration, :num_speakers, :speaker_desc, :genre, :annotation, :license, :citation
  before_destroy :remove_dirs
  
  validates :name, :presence => true
  validates :language, :presence => true
  validates :num_speakers, :inclusion => 1..9999
  #validates :description, :presence => true
  
  attr_accessor :upload_file
  
  def upload=(upload_file)
  	@upload_file = upload_file
  end
  
  def remove_dirs
  	FileUtils.rm_rf("corpora.files/#{self.utoken}/");
  	FileUtils.rm_rf("corpora.archives/#{self.utoken}/");
  end
  
end