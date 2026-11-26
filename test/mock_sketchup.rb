# Minimal fake SketchUp API - just enough to run the extension's code paths.
$loaded = {}
def file_loaded?(f) = $loaded[f]
def file_loaded(f) = ($loaded[f] = true)

class Numeric; def to_l = to_f; end
class String; def to_l = (DMACC::WallFramer::Framing.parse_len(self) || raise(ArgumentError)); end

module Attr
  def attrs = (@attrs ||= Hash.new { |h, k| h[k] = {} })
  def get_attribute(d, k, default = nil) = attrs[d].fetch(k, default)
  def set_attribute(d, k, v) = (attrs[d][k] = v)
end

module Geom
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
    def length = Math.sqrt(x * x + y * y + z * z)
    def length=(l); f = l / length; @x *= f; @y *= f; @z *= f; end
    def normalize = Vector3d.new(x / length, y / length, z / length)
    def *(o) = Vector3d.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
  end
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
    def -(o) = Vector3d.new(x - o.x, y - o.y, z - o.z)
    def offset(v, d = nil)
      v = v.normalize.tap { |u| u.length = d } if d
      Point3d.new(x + v.x, y + v.y, z + v.z)
    end
    def distance(o) = (self - o).length
  end
  class Transformation
    attr_reader :origin, :xaxis
    def initialize(o, x) = (@origin, @xaxis = o, x)
    def self.axes(o, x, _y, _z) = new(o, x)
    def self.translation(v) = new(Point3d.new(*v.to_a), Vector3d.new(1, 0, 0))
  end
  class BoundingBox; def add(*) = nil; end
end
Z_AXIS = Geom::Vector3d.new(0, 0, 1)
MB_YESNO = 4; IDYES = 6

module Sketchup
  class Color; def initialize(*a) = (@rgb = a); end
  class Material; include Attr; attr_accessor :color, :alpha, :name; def initialize(n) = (@name = n); end
  class Layer; attr_reader :name; def initialize(n) = (@name = n); end
  class Face
    attr_accessor :material, :back_material, :layer
    def initialize(pts) = (@pts = pts)
    def normal = Geom::Vector3d.new(0, 0, -1)
    def reverse! = self
    def pushpull(_d) = nil
    def edges = []
  end
  class Entity; include Attr; attr_accessor :name, :layer, :material; def deleted? = false; end
  class ComponentInstance < Entity
    attr_reader :definition, :transformation
    def initialize(d, t) = (@definition, @transformation = d, t)
  end
  class Entities
    include Enumerable
    def initialize = (@items = [])
    def each(&) = @items.each(&)
    def add_group = (Group.new.tap { |g| @items << g })
    def add_instance(d, t) = (ComponentInstance.new(d, t).tap { |i| @items << i })
    def add_face(*pts) = (Face.new(pts).tap { |f| @items << f })
    def clear! = @items.clear
    def size = @items.size
  end
  class Group < Entity
    attr_accessor :transformation
    attr_reader :entities
    def initialize = (@entities = Entities.new)
    def make_unique = self
    def transform!(t) = (o = transformation.origin; @transformation = Geom::Transformation.new(Geom::Point3d.new(o.x + t.origin.x, o.y + t.origin.y, o.z + t.origin.z), transformation.xaxis))
  end
  class Definition; include Attr; attr_reader :name, :entities; def initialize(n) = (@name, @entities = n, Entities.new); end
  class Coll
    include Enumerable
    def initialize(k) = (@k, @h = k, {})
    def [](n) = @h[n]
    def add(n) = (@h[n] = @k.new(n))
    def each(&) = @h.values.each(&)
  end
  class Selection
    include Enumerable
    def initialize = (@s = [])
    def each(&) = @s.each(&)
    def clear = @s.clear
    def add(e) = (@s << e)
  end
  class View; def zoom(*) = nil; end
  class Model
    include Attr
    attr_reader :entities, :definitions, :layers, :materials, :selection, :active_view, :ops
    attr_accessor :title
    def initialize
      @entities = Entities.new; @definitions = Coll.new(Definition); @layers = Coll.new(Layer)
      @materials = Coll.new(Material); @selection = Selection.new; @active_view = View.new; @ops = []; @title = 'student_house'
    end
    def start_operation(n, *) = @ops << n
    def commit_operation = nil
    def abort_operation = (@ops << :aborted)
    def select_tool(t) = (@tool = t)
  end
  @model = Model.new
  def self.active_model = @model
  def self.require(f) = Kernel.require(f)
end

module UI
  @messages = []
  @answers = {}
  class << self
    attr_reader :messages, :answers
    def messagebox(m, *_) = (@messages << m; IDYES)
    def menu(*) = Menu.new
    def add_context_menu_handler(&) = nil
    def inputbox(*) = @answers[:inputbox]
    def savepanel(*) = @answers[:savepanel]
    def openpanel(*) = @answers[:openpanel]
    def beep = nil
  end
  class Menu; def add_submenu(*) = Menu.new; def add_item(*) = nil; def add_separator = nil; end
  class Command; attr_accessor :tooltip, :status_bar_text, :small_icon, :large_icon; def initialize(*) = nil; end
  class Toolbar; def initialize(*) = nil; def add_item(*) = nil; def restore = nil; end
  class HtmlDialog
    STYLE_DIALOG = 1
    @all = []
    class << self; attr_reader :all; end
    attr_reader :cbs, :scripts, :file
    def initialize(**) = (@cbs = {}; @scripts = []; HtmlDialog.all << self)
    def set_file(f) = (@file = f)
    def set_html(h) = (@html = h)
    def add_action_callback(n, &b) = (@cbs[n] = b)
    def execute_script(s) = @scripts << s
    def show = (@vis = true)
    def visible? = @vis
    def close = (@vis = false)
    def bring_to_front = nil
    def fire(n, arg = '') = @cbs[n].call(nil, arg.is_a?(String) ? arg : JSON.generate(arg))
    def last(fn) = JSON.parse(@scripts.reverse.find { |s| s.start_with?("#{fn}(") }[(fn.size + 1)..-2])
  end
end

# ---- additions for the draw tool ----
X_AXIS = Geom::Vector3d.new(1, 0, 0); Y_AXIS = Geom::Vector3d.new(0, 1, 0)
VK_SHIFT = 16
GL_LINES = 1; GL_LINE_LOOP = 2
module Geom
  class Vector3d
    def clone = Vector3d.new(x, y, z)
    def normalize! = (l = length; @x /= l; @y /= l; @z /= l; self)
    def angle_between(o) = Math.acos([[(x * o.x + y * o.y + z * o.z) / (length * o.length), 1].min, -1].max)
    def to_a = [x, y, z]
  end
  class Point3d; def to_a = [x, y, z]; end
  class Transformation
    def yaxis = Z_AXIS * xaxis.normalize
    def zaxis = Z_AXIS
  end
  def self.intersect_line_plane(line, plane)
    p, v = line; z = plane[0].z
    t = (z - p.z) / v.z
    Point3d.new(p.x + v.x * t, p.y + v.y * t, z)
  end
end
module Sketchup
  class View
    def pickray(x, y) = [Geom::Point3d.new(x, y, 300), Geom::Vector3d.new(0, 0, -1)]
    def invalidate = nil
    attr_accessor :tooltip, :line_width, :drawing_color, :line_stipple
    def draw(*) = nil
    def draw_text(*) = nil
    def screen_coords(p) = p
  end
  class InputPoint
    VERTS = []
    attr_reader :position, :degrees_of_freedom
    def initialize(p = nil) = (@position = p; @degrees_of_freedom = 3)
    def pick(_v, x, y, _ref = nil)
      v = VERTS.find { |q| Math.hypot(q[0] - x, q[1] - y) < 1.0 }
      if v then @position = Geom::Point3d.new(v[0], v[1], 0); @degrees_of_freedom = 0
      else @position = Geom::Point3d.new(x + 0.3, y - 0.2, 40); @degrees_of_freedom = 2 # cursor on a wall face, 40" up
      end
    end
    def valid? = true
    def tooltip = ''
    def draw(*) = nil
  end
  class << self
    attr_accessor :vcb_value, :vcb_label, :status_text
  end
end

# ---- additions for the yard / install tool ----
module Geom
  class Transformation
    def initialize(o, x, y = nil, z = nil)
      @origin = o; @xaxis = x.normalize
      @z = z || Z_AXIS; @y = y || (@z * @xaxis)
    end
    def self.axes(o, x, y, z) = new(o, x, y, z)
    def yaxis = @y
    def zaxis = @z
    def apply_pt(p) = Point3d.new(@origin.x + @xaxis.x * p.x + @y.x * p.y + @z.x * p.z,
                                  @origin.y + @xaxis.y * p.x + @y.y * p.y + @z.y * p.z,
                                  @origin.z + @xaxis.z * p.x + @y.z * p.y + @z.z * p.z)
    def apply_vec(v) = Vector3d.new(@xaxis.x * v.x + @y.x * v.y + @z.x * v.z,
                                    @xaxis.y * v.x + @y.y * v.y + @z.y * v.z,
                                    @xaxis.z * v.x + @y.z * v.y + @z.z * v.z)
    def inverse = Inverse.new(self)
  end
  class Inverse
    def initialize(t) = (@t = t)
    def apply_pt(p)
      d = Vector3d.new(p.x - @t.origin.x, p.y - @t.origin.y, p.z - @t.origin.z)
      Point3d.new(*apply_vec(d).to_a)
    end
    def apply_vec(v)
      a = [@t.xaxis, @t.yaxis, @t.zaxis].map { |e| e.x * v.x + e.y * v.y + e.z * v.z }
      Vector3d.new(*a)
    end
  end
  class Point3d; def transform(t) = t.apply_pt(self); end
  class Vector3d; def transform(t) = t.apply_vec(self); end
end
module Sketchup
  class Entities; def add_text(t, p) = (Entity.new.tap { |e| e.name = t; @items << e }); end
  class View
    attr_accessor :ray
    def pickray(x, y) = (@ray || [Geom::Point3d.new(x, y, 300), Geom::Vector3d.new(0, 0, -1)])
  end
end
module Sketchup
  class Entities; def add_line(a, b) = (Entity.new.tap { |e| @items << e }); end
  class InputPoint
    def pick(_v, x, y, _ref = nil)
      @position = Geom::Point3d.new(x.to_f, y.to_f, 40); @degrees_of_freedom = 3
    end
  end
end
IDNO = 7
module UI
  class << self
    def inputbox(*a) = (v = @answers[:inputbox]; v.is_a?(Proc) ? v.call(*a) : v)
    def messagebox(m, *_) = (@messages << m; (v = @answers[:msg]) ? (v.is_a?(Proc) ? v.call(m) : v) : IDYES)
  end
end
module Sketchup
  @defaults = {}
  def self.read_default(s, k, d = nil) = @defaults.fetch([s, k], d)
  def self.write_default(s, k, v) = (@defaults[[s, k]] = v)
  def self.temp_dir = '/tmp'
  def self.install_from_archive(p, *_) = ($installed = p)
  module Http
    GET = 'GET'
    RESPONSES = {}
    Res = Struct.new(:status_code, :body)
    class Request
      def initialize(u, _m) = (@u = u)
      def start(&b) = b.call(self, RESPONSES[@u] || Res.new(404, ''))
    end
  end
end
module UI; def self.start_timer(*) = nil; end
