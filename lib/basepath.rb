require 'pathname'

module Basepath
  DOT_BASE = '.base'
  extend self

  def path_from_caller_line(caller_line)
    caller_line.sub(/:\d+(?::in `.*?')?$/, '')
  end

  def mine(file = false)
    path_to_caller = path_from_caller_line(caller.first)
    path = Pathname.new(path_to_caller).realpath
    file ? path : path.dirname
  end

  # used when setting consts and load_path
  def const_expand!(s)
    (s.sub!(RX_CONSTS, '') ? Object.const_get($1) : ::BASE_PATH).join(s);
  end

  def find_base(start_path)
    cur_path = start_path
    got_base = lambda { cur_path.join(DOT_BASE).exist? }
    cur_path = cur_path.parent until cur_path == cur_path.parent or got_base[]
    cur_path if got_base[]
  end

  def find_base!
    paths_tried = []
    index_of_require_line = caller.index { |line| line =~ /`require'$/ } \
      and caller_line_before_require = caller[index_of_require_line.succ]
    if index_of_require_line && caller_line_before_require
      path_from_requirer = Pathname.new(path_from_caller_line(caller_line_before_require)).realpath.dirname
      base_from_requirer = find_base(path_from_requirer)
      return base_from_requirer if base_from_requirer
      paths_tried << path_from_requirer
    end
    path_from_pwd = Pathname.new(Dir.pwd).realpath
    pwd_path_parent_of_requirer_path = index_of_require_line && "#{path_from_requirer}/".index("#{path_from_pwd}/") == 0
    if not pwd_path_parent_of_requirer_path
      base_from_pwd = find_base(path_from_pwd)
      return base_from_pwd if base_from_pwd
      paths_tried << path_from_pwd
    end
    err = "Can't find #{DOT_BASE} for BASE_PATH. (started at #{paths_tried.first}"
    err << ", then tried #{paths_tried[1]}" if paths_tried[1]
    err << ")"
    raise err
  end

  def resolve!
    return if Object.const_defined?("BASE_PATH")
    Object.const_set :BASE_PATH, find_base!

    # read dot_base
    base_conf = IO.read(::BASE_PATH.join(DOT_BASE)).strip.gsub(/[ \t]/, '').gsub(/\n+/, "\n")\
      .scan(/^\[(\w+)\]((?:\n[^\[].*)*)/)\
      .inject(Hash.new('')) { |h, (k, s)| h[k.to_sym] = s.strip; h }
    base_conf.values.each { |s| s.gsub!(/\s*#.*\n/, "\n") }

    # set path consts
    k_order   = [] # ruby 1.8 doesn't retain hash key order
    consts    = base_conf[:consts].scan(/([A-Z][A-Z0-9_]*)=(.+)/).inject({}) { |h, (k, v)| k_order << k; h[k] = v; h }
    const_set :RX_CONSTS, /^(#{consts.keys.map(&Regexp.method(:escape)).join('|')})(?:\/|$)/
    k_order.each { |k| Object.const_set(k, Basepath.const_expand!(consts[k])) }

    # set load_paths
    load_paths = base_conf[:load_paths].split("\n").map { |s|
      Dir[Basepath.const_expand!(s).to_s] }.flatten.select { |s|
        File.directory? s }
    $LOAD_PATH.unshift(*load_paths)

    # requires
    loaded = caller(0).map { |s| s[/\A(.+?)(?:\.rb)?:\d+(?::in `.*?')?\z/, 1] }.compact.uniq
    globs, names = base_conf[:requires].split("\n").partition { |s| s =~ /\*/ }
    names.concat \
      globs.map { |s| Dir[Basepath.const_expand!(s).to_s + ".rb"] }\
        .flatten.select { |s| File.file? s }.map { |s| s.sub(/\.rb$/, '') }
    names.each { |lib| require lib }

    # includes
    base_conf[:includes].split("\n").each { |k| include Object.const_get(k.strip) }
  end
end

Basepath.resolve!
