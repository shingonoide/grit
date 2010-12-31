require 'tempfile'
module Grit

  class Git
    class GitTimeout < RuntimeError
      attr_accessor :command
      attr_accessor :bytes_read

      def initialize(command = nil, bytes_read = nil)
        @command = command
        @bytes_read = bytes_read
      end
    end

    # Raised when a native git command exits with non-zero.
    class CommandFailed < StandardError
      # The full git command that failed as a String.
      attr_reader :command

      # The integer exit status.
      attr_reader :exitstatus

      # Everything output on the command's stderr as a String.
      attr_reader :err

      def initialize(command, exitstatus, err='')
        @command = command
        @exitstatus = exitstatus
        @err = err
        super "Command exited with #{exitstatus}: #{command}"
      end
    end

    undef_method :clone

    include GitRuby

    def exist?
      File.exist?(self.git_dir)
    end

    def put_raw_object(content, type)
      ruby_git.put_raw_object(content, type)
    end

    def object_exists?(object_id)
      ruby_git.object_exists?(object_id)
    end

    def select_existing_objects(object_ids)
      object_ids.select do |object_id|
        object_exists?(object_id)
      end
    end

    class << self
      attr_accessor :git_timeout, :git_max_size
      def git_binary
        @git_binary ||=
          ENV['PATH'].split(':').
            map  { |p| File.join(p, 'git') }.
            find { |p| File.exist?(p) }
      end
      attr_writer :git_binary
    end

    self.git_timeout  = 10
    self.git_max_size = 5242880 # 5.megabytes

    def self.with_timeout(timeout = 10.seconds)
      old_timeout = Grit::Git.git_timeout
      Grit::Git.git_timeout = timeout
      yield
      Grit::Git.git_timeout = old_timeout
    end

    attr_accessor :git_dir, :work_tree

    def initialize(git_dir, work_tree = nil)
      self.git_dir    = git_dir
      self.work_tree  = work_tree
    end

    def shell_escape(str)
      str.to_s.gsub("'", "\\\\'").gsub(";", '\\;')
    end
    alias_method :e, :shell_escape

    def shell_quote(str)
      if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/ 
        "\"#{str}\""
      else 
        "'#{str}'"
      end
    end
    alias_method :q, :shell_quote

    # Check if a normal file exists on the filesystem
    #   +file+ is the relative path from the Git dir
    #
    # Returns Boolean
    def fs_exist?(file)
      File.exist?(File.join(self.git_dir, file))
    end

    # Read a normal file from the filesystem.
    #   +file+ is the relative path from the Git dir
    #
    # Returns the String contents of the file
    def fs_read(file)
      File.read(File.join(self.git_dir, file))
    end

    # Write a normal file to the filesystem.
    #   +file+ is the relative path from the Git dir
    #   +contents+ is the String content to be written
    #
    # Returns nothing
    def fs_write(file, contents)
      path = File.join(self.git_dir, file)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'w') do |f|
        f.write(contents)
      end
    end

    # Delete a normal file from the filesystem
    #   +file+ is the relative path from the Git dir
    #
    # Returns nothing
    def fs_delete(file)
      FileUtils.rm_rf(File.join(self.git_dir, file))
    end

    # Move a normal file
    #   +from+ is the relative path to the current file
    #   +to+ is the relative path to the destination file
    #
    # Returns nothing
    def fs_move(from, to)
      FileUtils.mv(File.join(self.git_dir, from), File.join(self.git_dir, to))
    end

    # Make a directory
    #   +dir+ is the relative path to the directory to create
    #
    # Returns nothing
    def fs_mkdir(dir)
      FileUtils.mkdir_p(File.join(self.git_dir, dir))
    end

    # Chmod the the file or dir and everything beneath
    #   +file+ is the relative path from the Git dir
    #
    # Returns nothing
    def fs_chmod(mode, file = '/')
      FileUtils.chmod_R(mode, File.join(self.git_dir, file))
    end

    def list_remotes
      remotes = []
      Dir.chdir(File.join(self.git_dir, 'refs/remotes')) do
        remotes = Dir.glob('*')
      end
      remotes
    rescue
      []
    end

    def create_tempfile(seed, unlink = false)
      path = Tempfile.new(seed).path
      File.unlink(path) if unlink
      return path
    end

    def commit_from_sha(id)
      git_ruby_repo = GitRuby::Repository.new(self.git_dir)
      object = git_ruby_repo.get_object_by_sha1(id)

      if object.type == :commit
        id
      elsif object.type == :tag
        object.object
      else
        ''
      end
    end

    def check_applies(head_sha, applies_sha)
      git_index = create_tempfile('index', true)
      (o1, exit1) = raw_git("git read-tree #{head_sha} 2>/dev/null", git_index)
      (o2, exit2) = raw_git("git diff #{applies_sha}^ #{applies_sha} | git apply --check --cached >/dev/null 2>/dev/null", git_index)
      return (exit1 + exit2)
    end

    def get_patch(applies_sha)
      git_index = create_tempfile('index', true)
      (patch, exit2) = raw_git("git diff #{applies_sha}^ #{applies_sha}", git_index)
      patch
    end

    def apply_patch(head_sha, patch)
      git_index = create_tempfile('index', true)

      git_patch = create_tempfile('patch')
      File.open(git_patch, 'w+') { |f| f.print patch }

      raw_git("git read-tree #{head_sha} 2>/dev/null", git_index)
      (op, exit) = raw_git("git apply --cached < #{git_patch}", git_index)
      if exit == 0
        return raw_git("git write-tree", git_index).first.chomp
      end
      false
    end

    # RAW CALLS WITH ENV SETTINGS
    def raw_git_call(command, index)
      tmp = ENV['GIT_INDEX_FILE']
      ENV['GIT_INDEX_FILE'] = index
      out = `#{command}`
      after = ENV['GIT_INDEX_FILE'] # someone fucking with us ??
      ENV['GIT_INDEX_FILE'] = tmp
      if after != index
        raise 'environment was changed for the git call'
      end
      [out, $?.exitstatus]
    end

    def raw_git(command, index)
      output = nil
      Dir.chdir(self.git_dir) do
        output = raw_git_call(command, index)
      end
      output
    end
    # RAW CALLS WITH ENV SETTINGS END


    # Execute a git command, bypassing any library implementation.
    #
    # cmd - The name of the git command as a Symbol. Underscores are
    #   converted to dashes as in :rev_parse => 'rev-parse'.
    # options - Command line option arguments passed to the git command.
    #   Single char keys are converted to short options (:a => -a).
    #   Multi-char keys are converted to long options (:arg => '--arg').
    #   Underscores in keys are converted to dashes. These special options
    #   are used to control command execution and are not passed in command
    #   invocation:
    #     :timeout - Maximum amount of time the command can run for before
    #       being aborted. When true, use Grit::Git.git_timeout; when numeric,
    #       use that number of seconds; when false or 0, disable timeout.
    #     :base - Set false to avoid passing the --git-dir argument when
    #       invoking the git command.
    #     :env - Hash of environment variable key/values that are set on the
    #       child process.
    #     :raise - When set true, commands that exit with a non-zero status
    #       raise a CommandFailed exception. This option is available only on
    #       platforms that support fork(2).
    # args - Non-option arguments passed on the command line.
    #
    # Optionally yields to the block an IO object attached to the child
    # process's STDIN.
    #
    # Examples
    #   git.native(:rev_list, {:max_count => 10, :header => true}, "master")
    #
    # Returns a String with all output written to the child process's stdout.
    # Raises Grit::Git::GitTimeout when the timeout is exceeded or when more
    #   than Grit::Git.git_max_size bytes are output.
    # Raises Grit::Git::CommandFailed when the :raise option is set true and the
    #   git command exits with a non-zero exit status. The CommandFailed's #command,
    #   #exitstatus, and #err attributes can be used to retrieve additional
    #   detail about the error.
    def native(cmd, options = {}, *args, &block)
      args     = args.first if args.size == 1 && args[0].is_a?(Array)
      args.map!    { |a| a.to_s.strip }
      args.reject! { |a| a.empty? }

      # special option arguments
      env = options.delete(:env) || {}
      raise_errors = options.delete(:raise)

      # fall back to using a shell when the last argument looks like it wants to
      # start a pipeline for compatibility with previous versions of grit.
      return run(prefix, cmd, '', options, args) if args[-1].to_s[0] == ?|

      # more options
      input    = options.delete(:input)
      timeout  = options.delete(:timeout); timeout = true if timeout.nil?
      base     = options.delete(:base);    base    = true if base.nil?
      chdir    = options.delete(:chdir)

      # build up the git process argv
      argv = []
      argv << Git.git_binary
      argv << "--git-dir=#{git_dir}" if base
      argv << cmd.to_s.tr('_', '-')
      argv.concat(options_to_argv(options))
      argv.concat(args)

      # run it and deal with fallout
      Grit.log(argv.join(' ')) if Grit.debug

      process =
        Grit::Process.new(argv, env,
          :input   => input,
          :chdir   => chdir,
          :timeout => (Grit::Git.git_timeout if timeout == true),
          :max     => (Grit::Git.git_max_size if timeout == true)
        )
      status = process.status
      Grit.log(process.out) if Grit.debug
      Grit.log(process.err) if Grit.debug
      if raise_errors && !status.success?
        raise CommandFailed.new(argv.join(' '), status.exitstatus, process.err)
      else
        process.out
      end
    rescue Grit::Process::TimeoutExceeded, Grit::Process::MaximumOutputExceeded
      raise GitTimeout, argv.join(' ')
    end

    # Methods not defined by a library implementation execute the git command
    # using #native, passing the method name as the git command name.
    #
    # Examples:
    #   git.rev_list({:max_count => 10, :header => true}, "master")
    def method_missing(cmd, options={}, *args, &block)
      native(cmd, options, *args, &block)
    end

    # Transform a ruby-style options hash to command-line arguments sutiable for
    # use with Kernel::exec. No shell escaping is performed.
    #
    # Returns an Array of String option arguments.
    def options_to_argv(options)
      argv = []
      options.each do |key, val|
        if key.to_s.size == 1
          if val == true
            argv << "-#{key}"
          elsif val == false
            # ignore
          else
            argv << "-#{key}"
            argv << val.to_s
          end
        else
          if val == true
            argv << "--#{key.to_s.tr('_', '-')}"
          elsif val == false
            # ignore
          else
            argv << "--#{key.to_s.tr('_', '-')}=#{val}"
          end
        end
      end
      argv
    end

    # Simple wrapper around Timeout::timeout.
    #
    # seconds - Float number of seconds before a Timeout::Error is raised. When
    #   true, the Grit::Git.git_timeout value is used. When the timeout is less
    #   than or equal to 0, no timeout is established.
    #
    # Raises Timeout::Error when the timeout has elapsed.
    def timeout_after(seconds)
      seconds = self.class.git_timeout if seconds == true
      if seconds && seconds > 0
        Timeout.timeout(seconds) { yield }
      else
        yield
      end
    end

    # DEPRECATED OPEN3-BASED COMMAND EXECUTION

    def run(prefix, cmd, postfix, options, args, &block)
      timeout  = options.delete(:timeout) rescue nil
      timeout  = true if timeout.nil?

      base     = options.delete(:base) rescue nil
      base     = true if base.nil?

      if input = options.delete(:input)
        block = lambda { |stdin| stdin.write(input) }
      end

      opt_args = transform_options(options)

      ext_args = args.reject { |a| a.empty? }.map { |a| (a == '--' || a[0].chr == '|'  || Grit.no_quote) ? a : q(e(a)) }
      call = "#{prefix}#{Git.git_binary}"
      call += " --work-tree=#{q(self.work_tree)}" if self.work_tree
      call += " --git-dir=#{q(self.git_dir)} #{cmd.to_s.gsub(/_/, '-')} #{(opt_args + ext_args).join(' ')}#{e(postfix)}"

      Grit.log(call) if Grit.debug
      response, err = timeout ? sh(call, &block) : wild_sh(call, &block)
      Grit.log(response) if Grit.debug
      Grit.log(err) if Grit.debug
      response
    end

    def sh(command, &block)
      process =
        Grit::Process.new(
          command, {},
          :timeout => Git.git_timeout,
          :max     => Git.git_max_size
        )
      [process.out, process.err]
    rescue Grit::Process::TimeoutExceeded, Grit::Process::MaximumOutputExceeded
      raise GitTimeout, command
    end

    def wild_sh(command, &block)
      process = Grit::Process.new(command)
      [process.out, process.err]
    end

    # Transform Ruby style options into git command line options
    #   +options+ is a hash of Ruby style options
    #
    # Returns String[]
    #   e.g. ["--max-count=10", "--header"]
    def transform_options(options)
      args = []
      options.keys.each do |opt|
        if opt.to_s.size == 1
          if options[opt] == true
            args << "-#{opt}"
          elsif options[opt] == false
            # ignore
          else
            val = options.delete(opt)
            args << "-#{opt.to_s} '#{e(val)}'"
          end
        else
          if options[opt] == true
            args << "--#{opt.to_s.gsub(/_/, '-')}"
          elsif options[opt] == false
            # ignore
          else
            val = options.delete(opt)
            args << "--#{opt.to_s.gsub(/_/, '-')}='#{e(val)}'"
          end
        end
      end
      args
    end
  end # Git

end # Grit
