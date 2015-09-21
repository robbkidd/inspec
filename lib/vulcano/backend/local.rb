# encoding: utf-8
require 'etc'
require 'rbconfig'

if IO.respond_to?(:popen4)
  def open4(*args)
    IO.popen4(*args)
  end
else
  require 'open4'
end

module Vulcano::Backends
  class Local < Vulcano.backend(1)
    name 'local'

    attr_reader :os
    def initialize(conf)
      @conf = conf
      @files = {}
      @os = OS.new(self)
    end

    def file(path)
      @files[path] ||= File.new(self, path)
    end

    def run_command(cmd)
      Command.new(cmd)
    end

    def to_s
      'Local Command Runner'
    end

    class OS < OSCommon
      def initialize(backend)
        super(backend, { family: detect_local_os })
      end

      private

      def detect_local_os
        case ::RbConfig::CONFIG['host_os']
        when /aix(.+)$/
          return 'aix'
        when /darwin(.+)$/
          return 'darwin'
        when /hpux(.+)$/
          return 'hpux'
        when /linux/
          return 'linux'
        when /freebsd(.+)$/
          return 'freebsd'
        when /openbsd(.+)$/
          return 'openbsd'
        when /netbsd(.*)$/
          return 'netbsd'
        when /solaris2/
          return 'solaris2'
        when /mswin|mingw32|windows/
          # After long discussion in IRC the "powers that be" have come to a consensus
          # that no Windows platform exists that was not based on the
          # Windows_NT kernel, so we herby decree that "windows" will refer to all
          # platforms built upon the Windows_NT kernel and have access to win32 or win64
          # subsystems.
          return 'windows'
        else
          return ::RbConfig::CONFIG['host_os']
        end
      end
    end

    class Command
      attr_reader :stdout, :stderr, :exit_status
      def initialize(cmd)
        @cmd = cmd

        pid, stdin, stdout, stderr = open4(cmd)
        stdin.close
        _, status = Process.waitpid2 pid

        @stdout = stdout.read
        @stderr = stderr.read
        @exit_status = status.exitstatus
      rescue Errno::ENOENT => _
        @exit_status ||= 1
      end
    end

    class File < LinuxFile
      def content
        @content ||= ::File.read(@path, encoding: 'UTF-8')
      rescue StandardError => _
        nil
      end

      %w{
        exists? file? socket? directory? symlink? pipe?
      }.each do |m|
        define_method m.to_sym do
          ::File.method(m.to_sym).call(@path)
        end
      end

      def link_path
        return nil unless symlink?
        @link_path ||= ::File.readlink(@path)
      end

      def block_device?
        ::File.blockdev?(@path)
      end

      def character_device?
        ::File.chardev?(@path)
      end

      private

      def pw_username(uid)
        Etc.getpwuid(uid).name
      rescue ArgumentError => _
        nil
      end

      def pw_groupname(gid)
        Etc.getgrgid(gid).name
      rescue ArgumentError => _
        nil
      end

      def stat
        return @stat unless @stat.nil?

        begin
          file_stat = ::File.lstat(@path)
        rescue StandardError => _err
          return @stat = {}
        end

        tmask = file_stat.mode
        type = TYPES.find { |_, mask| mask & tmask == mask }
        type ||= [:unknown]

        @stat = {
          type: type[0],
          mode: tmask & 00777,
          mtime: file_stat.mtime.to_i,
          size: file_stat.size,
          user: pw_username(file_stat.uid),
          group: pw_groupname(file_stat.gid),
        }

        res = @backend.run_command("stat #{@spath} 2>/dev/null --printf '%C'")
        if res.exit_status == 0 && !res.stdout.empty? && res.stdout != '?'
          @stat[:selinux_label] = res.stdout.strip
        end

        @stat
      end
    end
  end
end