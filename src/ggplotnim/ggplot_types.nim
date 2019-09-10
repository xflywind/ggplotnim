import options, tables, hashes, macros
import chroma
import formula
import ginger

type
  Aesthetics* = object
    # In principle `x`, `y` are `Scale(scKind: scLinearData)`!
    # possibly `scTranformedData`.
    x*: Option[string]
    y*: Option[string]
    # Replace these by e.g. `color: Option[Scale]` and have `Scale` be variant
    # type that stores its kind `kind: scColor` and `key: string`.
    fill*: Option[Scale] # classify by fill color
    color*: Option[Scale] # classify by color
    size*: Option[Scale] # classify by size
    shape*: Option[Scale] # classify by shape

  ScaleKind* = enum
    scLinearData, scTransformedData, scColor, scFillColor, scShape, scSize

  PositionKind* = enum
    pkIdentity = "identity"
    pkStack = "stack"
    pkDodge = "dodge"
    pkFill = "fill"

  DiscreteKind* = enum
    dcDiscrete, dcContinuous

  ScaleValue* = object
    case kind*: ScaleKind
    of scLinearData:
      # just stores a data value
      val*: Value
    of scTransformedData:
      # data under some transformation. E.g. log, tanh, ...
      rawVal*: Value
      # where `trans` is our assigned transformation function
      trans*: proc(v: Value): Value
    of scFillColor, scColor:
      # stores a color
      color*: Color
    of scShape:
      # a marker kind
      marker*: MarkerKind
    of scSize:
      # a size of something, e.g. a marker
      size*: float

  # TODO: should not one scale belong to only one axis?
  # But if we do that, how do we find the correct scale in the seq[Scale]?
  # Replace seq[Scale] by e.g. Table[string, Scale] where string is some
  # static identifier we can calculate to retrieve it?
  # e.g. `xaxis`, `<name of geom>.xaxis` etc.?
  Scale* = object
    # the column which this scale corresponds to
    col*: string
    scKind*: ScaleKind
    case kind*: DiscreteKind
    of dcDiscrete:
      # For discrete data this is a good solution. How about continuous data?
      valueMap*: OrderedTable[Value, ScaleValue]
      # seq of labels to access via index
      labelSeq*: seq[Value]
    of dcContinuous:
      # For continuous we might want to add a `Scale` in the ginger sense
      dataScale*: ginger.Scale
      # with this we can calculate on the fly the required values given the
      # data

  Facet* = object
    columns*: seq[string]

  # helper object to compose `ggsave` via `+` with `ggplot`
  # Uses the default ``cairo`` backend
  Draw* = object
    fname*: string

  # helper object to compose `ggvega` via `+` with `ggplot`
  # Used to show a plot using the Vega-Lite backend
  VegaDraw* = object
    discard

  GeomKind* = enum
    gkPoint, gkBar, gkHistogram, gkFreqPoly, gkTile, gkLine
  Geom* = object
    style*: Option[Style] # if set, apply this style instead of parent's
    position*: PositionKind
    aes*: Aesthetics # a geom can have its own aesthetics. Needs to be part of
                    # the `Geom`, because if we add it to `GgPlot` we lose track
                    # of which geom it corresponds to
    case kind*: GeomKind
    of gkHistogram, gkFreqPoly:
      numBins*: int # number of bins
      binWidth*: float # width of bins in terms of the data
    else:
      discard

  GgPlot*[T] = object
    data*: T
    title*: string
    subtitle*: string
    # GgPlot can only contain a single `aes` by itself. Geoms may contain
    # seperate ones
    aes*: Aesthetics
    numXticks*: int
    numYticks*: int
    facet*: Option[Facet]
    geoms*: seq[Geom]

proc `==`*(s1, s2: Scale): bool =
  if s1.kind == s2.kind and
     s1.col == s2.col:
    # the other fields ``will`` be computed to the same!
    result = true
  else:
    result = false

# Workaround. For some reason `hash` for `Style` isn't found if defined in
# ginger..
proc hash*(s: Style): Hash =
  result = hash($s.color)
  result = result !& hash(s.size)
  result = result !& hash(s.lineType)
  result = result !& hash(s.lineWidth)
  result = result !& hash($s.fillColor)
  result = !$result

proc hash*(x: ScaleValue): Hash =
  result = hash(x.kind.int)
  case x.kind:
  of scLinearData:
    result = result !& hash(x.val)
  of scTransformedData:
    result = result !& hash(x.rawVal)
    # TODO: Hash proc?
  of scColor:
    result = result !& hash($x.color)
  of scFillColor:
    result = result !& hash($x.color & "FILL")
  of scShape:
    result = result !& hash(x.marker)
  of scSize:
    result = result !& hash(x.size)
  result = !$result

proc hash*(x: Scale): Hash =
  result = hash(x.scKind.int)
  result = result !& hash(x.col)
  case x.kind:
  of dcDiscrete:
    for k, v in x.valueMap:
      result = result !& hash(k)
      result = result !& hash(v)
    result = result !& hash(x.labelSeq)
  of dcContinuous:
    result = result !& hash(x.dataScale)
  result = !$result

proc `$`*(f: Facet): string =
  result = "(columns: "
  for i, x in f.columns:
    if i == f.columns.len - 1:
      result.add x & ")"
    else:
      result.add x & ", "

proc `$`*(aes: Aesthetics): string =
  result = "("
  if aes.x.isSome:
    result.add "x: " & $aes.x.unsafeGet
  if aes.y.isSome:
    result.add "y: " & $aes.y.unsafeGet
  if aes.size.isSome:
    result.add "size: " & $aes.size.unsafeGet
  if aes.shape.isSome:
    result.add "shape: " & $aes.shape.unsafeGet
  if aes.color.isSome:
    result.add "color: " & $aes.color.unsafeGet
  if aes.fill.isSome:
    result.add "fill: " & $aes.fill.unsafeGet
  result.add ")"

proc `$`*(g: Geom): string =
  result = "(kind: " & $g.kind & ","
  result.add "aes: " & $g.aes
  result.add ")"

macro typeName(x: typed): untyped =
  let str = x.getTypeInst.repr
  result = quote do:
    `str`

proc `$`*[T](p: GgPlot[T]): string =
  result = "(data: " & typeName(p.data)
  result.add ", title: " & $p.title
  result.add ", subtitle: " & $p.subtitle
  result.add ", aes: " & $p.aes
  result.add ", numXTicks " & $p.numXTicks
  result.add ", numYTicks " & $p.numXTicks
  result.add ", facet: " & $p.facet
  result.add ", geoms: "
  for g in p.geoms:
    result.add $g
  result.add ")"