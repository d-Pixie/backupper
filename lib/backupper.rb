# encoding: UTF-8
# Based on Matt Connollys work with the rails-backup-migrate gem.

require "backupper/version"
require 'tmpdir'
require 'fileutils'

module Backupper

  VERBOSE = (ENV['verbose'] || ENV['VERBOSE'] || Rails.env == 'development' ? true : false)
  TMP_DIR = "tmp/backup"

  def initialize( version )
    @version = version
    self.reset
  end

  def reset
    @archive_file = nil
    @files_to_archive = []
    @files_to_delete_on_cleanup = []
  end

  def export(list_of_tables = nil)
    self.save_db_to_yml(list_of_tables)
    self.create_archive
    self.archive_file
  end

  def import(tmp, list_of_tables = nil)
    require 'fileutils'
    timestamp = Time.now.strftime("%Y%m%d%H%M%S")

    # Save a local backup so that we can restore later
    begin
      Rails.logger.info "**** Saving local backup" if VERBOSE
      self.save_db_to_yml(list_of_tables)
      self.create_archive("tmp/local_backup_#{timestamp}.tgz")
      local_copy = self.archive_file
      self.reset
    rescue => e
      Rails.logger.error "**** "+e.inspect
      Rails.logger.info "**** Rescuing local backup" if VERBOSE
      # Creating of local backup failed
      exit_code = -1
    else
      # Process uploaded file
      begin
        Rails.logger.info "**** Importing" if VERBOSE
        FileUtils.cp tmp.tempfile.path, File.join(Rails.root, tmp.original_filename)
        self.clear_tables(list_of_tables)
        self.unpack_archive File.join(Rails.root, tmp.original_filename)
        self.restore_db_from_yml(list_of_tables)
      rescue => e
        Rails.logger.error "**** "+e.inspect
        Rails.logger.info "**** Rescuing import" if VERBOSE
        # Import failed. Restore local backup
        self.clear_tables(list_of_tables)
        Rails.logger.info "*.*.*"+local_copy.inspect
        self.unpack_archive local_copy
        self.restore_db_from_yml(list_of_tables)
        exit_code = -2
      else
        Rails.logger.info "**** Finishing import" if VERBOSE
        exit_code = 0
      end
    end

    Rails.logger.info "**** Cleaning up" if VERBOSE
    FileUtils.rm_f local_copy
    FileUtils.rm_f File.join(Rails.root, tmp.original_filename)
    FileUtils.rmtree File.join(Rails.root, "tmp/backup")
    @files_to_delete_on_cleanup.each do |file|
      FileUtils.rm_f file
    end

    return exit_code
  end

  # list the tables we should backup, excluding ones we can ignore
  def interesting_tables(list_of_tables = nil)
    Rails.logger.info "+++"+self.connection.tables.inspect
    if list_of_tables.nil?
      self.connection.tables.sort.reject do |tbl|
        %w(schema_migrations sessions public_exceptions).include?(tbl)
      end
    else
      self.connection.tables.sort.keep_if do |tbl|
        list_of_tables.include?(tbl)
      end
    end
  end

  # add a path to be archived. Expected path to be relative to Rails.root. This is where the archive
  # will be created so that uploaded files (the 'files' dir) can be reference in place without needing to be copied.
  def add_to_archive path
    # check it's relative to Rails.root
    raise "File '#{path}' does not exist" unless File.exist? path or File.exist? File.join(Rails.root, path)

    expanded_path = File.expand_path(path)
    if expanded_path.start_with?(rails_root.to_s)
      # remove rails_root from absolute path
      relative = expanded_path.sub(rails_root + "/" + TMP_DIR + File::SEPARATOR,'')
      if expanded_path.length == relative.length
        relative = '../../'+expanded_path.sub(rails_root + File::SEPARATOR,'')
      end
      # add to list
      Rails.logger.info "Adding relative path: '#{relative}'" if VERBOSE
      @files_to_archive << relative
    else
      raise "Cannot add a file that is not under Rails root directory. (#{expanded_path} not under #{rails_root})"
    end
  end

  def files_to_archive
    @files_to_archive
  end

  def archive_file
    @archive_file
  end

  # get a temp directory to be used for the backup
  # the value is cached so it can be reused throughout the process
  def temp_dir
    @temp_dir ||= Dir.mktmpdir
  end

  # delete any working files
  def clean_up
    Rails.logger.info "cleaning up." if VERBOSE
    FileUtils.rmtree temp_dir
    @temp_dir = nil
    @files_to_delete_on_cleanup.each do |f|
      if File::directory? f
        FileUtils.rm_r f
      else
        FileUtils.rm f
      end
    end
    @files_to_delete_on_cleanup = []
  end

  # create the archive .tgz file in the requested location
  def create_archive backup_file = "tmp/backup.tgz"
    absolute = File::expand_path backup_file
    Rails.logger.info "creating archive ... #{absolute}" if VERBOSE
    @archive_file = absolute
    Rails.logger.info %x[tar -czf #{absolute} -C #{rails_root} #{files_to_archive.join ' '}] if VERBOSE
  end

  # unpack the requested file
  def unpack_archive file_name = "backup.tgz"
    raise "File '#{file_name}' does not exist" unless File.exist? file_name or File.exist? File.join(Rails.root, file_name)
    @files_to_delete_on_cleanup = %x[tar -tf "#{File.basename(file_name)}"].split("\n")
    Dir::chdir rails_root
    Rails.logger.info %x[tar -xvf "#{File.basename(file_name)}"] if VERBOSE
  end

  # remove all data from tables
  def clear_tables(list_of_tables_to_clear = nil)
    Rails.logger.info "Clearing all data from database..." if VERBOSE
    interesting_tables(list_of_tables_to_clear).each do |tbl|
      Rails.logger.info "Clearing #{tbl}..." if VERBOSE
      self.connection.delete("DELETE FROM #{tbl}")
    end
  end

  # save the required database tables to .yml files in a folder and add them to the backup
  def save_db_to_yml(list_of_tables_to_export = nil)
    Rails.logger.info "Saving DB to Yaml ... #{interesting_tables(list_of_tables_to_export)}" if VERBOSE
    FileUtils.chdir rails_root
    FileUtils.mkdir_p 'tmp/backup'
    FileUtils.chdir 'tmp/backup'

    @mysql = self.connection.class.to_s =~ /mysql/i

    interesting_tables(list_of_tables_to_export).each do |tbl|
      Rails.logger.info "Writing #{tbl}..." if VERBOSE
      File.open("#{tbl}.yml", 'w+') do |f|
        records = self.connection.select_all("SELECT * FROM #{tbl}")
        # we need to convert Mysql::Time objects into standard ruby time objects because they do not serialise
        # into YAML on their own at all, let alone in a way that would be compatible with other databases
        # we also need to catch any paperclip attached files and save them ...
        records.map! do |record|
          record.inject({}) do |memo, (k,v)|
            if @mysql and v.class.name == "Mysql::Time"
              memo[k] = datetime_from_mysql_time(v)
            else
              memo[k] = v
            end

            # This really just gets the real, relative path out from a paperclip attachment
            add_to_archive 'public'+Object::const_get(tbl.classify).find(record['id']).send(k.gsub("_file_name", "")).to_s.slice(0..-12) if k.ends_with? "_file_name"

            memo
          end
        end
        f << YAML.dump(records)
      end
      @files_to_delete_on_cleanup << File::expand_path("#{tbl}.yml")
      add_to_archive "tmp/backup/#{tbl}.yml"
    end

    FileUtils.chdir rails_root
  end


  def restore_db_from_yml(list_of_tables_to_import = nil)
    FileUtils.chdir File.join(rails_root, 'tmp/backup')

    interesting_tables(list_of_tables_to_import).each do |tbl|
      raise "File 'tmp/backup/#{tbl}.yml' does not exist" unless File.exist? "#{tbl}.yml"
      ActiveRecord::Base.transaction do
        Rails.logger.info "Loading #{tbl}..." if VERBOSE
        YAML.load_file("#{tbl}.yml").each do |fixture|
          self.connection.execute "INSERT INTO #{tbl} (#{fixture.keys.map{|k| "`#{k}`"}.join(",")}) VALUES (#{fixture.values.collect { |value| ActiveRecord::Base.connection.quote(value) }.join(",")})", 'Fixture Insert'
        end
      end
    end
  end

  def rails_root
    # in ruby 1.9.3, `Rails.root` is a Pathname object, that plays mess with string comparisons
    # so we'll ensure we have a string
    Rails.root.to_s
  end

  private

  def datetime_from_mysql_time(mysql_time)
      year = mysql_time.year
      month = [1,mysql_time.month].max
      day = [1,mysql_time.day].max
      DateTime.new year, month, day, mysql_time.hour, mysql_time.minute, mysql_time.second
  end

end
