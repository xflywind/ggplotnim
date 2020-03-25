## .. include:: ./docs/ggplotnim.rst

import sequtils, tables, sets, algorithm, strutils, macros
import parsecsv, streams, strutils, hashes, sugar, math

import ginger except Scale
export ginger.types

from seqmath import linspace

import persvector
export persvector

import ggplotnim / formula
export formula

import ggplotnim / [
  ggplot_utils, ggplot_types,
  # utils dealing with scales
  ggplot_scales,
  # first stage of drawing: collect and fill `Scales`:
  collect_and_fill,
  # second stage of drawing: post process the scales (not required to be imported
  # in this module)
  # postprocess_scales,
  ggplot_drawing, # third stage: the actual drawing
  # vega backend
  vega_utils
]
export ggplot_types
export ggplot_utils

import ggplotnim / colormaps / viridisRaw

import chroma
export chroma

export sets

import options
export options

# Ids start at 1, because `0` is our magic value for cases where the
# id does not matter!
var IdCounter = 1'u16
template incId(): uint16 =
  let old = IdCounter
  inc IdCounter
  old

proc orNone(s: string): Option[string] =
  ## returns either a `some(s)` if s.len > 0 or none[string]()
  if s.len == 0: none[string]()
  else: some(s)

proc orNone(f: float): Option[float] =
  ## returns either a `some(f)` if `classify(f) != NaN` or none[float]()
  if classify(f) != fcNaN: some(f)
  else: none[float]()

proc orNoneScale[T: string | FormulaNode](s: T, scKind: static ScaleKind, axKind = akX): Option[Scale] =
  ## returns either a `some(Scale)` of kind `ScaleKind` or `none[Scale]` if
  ## `s` is empty
  if ($s).len > 0:
    when T is string:
      let fs = f{s}
    else:
      let fs = s
    case scKind
    of scLinearData:
      result = some(Scale(scKind: scLinearData, col: fs, axKind: axKind))
    of scTransformedData:
      result = some(Scale(scKind: scTransformedData, col: fs, axKind: axKind))
    else:
      result = some(Scale(scKind: scKind, col: fs))
  else:
    result = none[Scale]()

proc aes*[A; B; C; D; E; F; G; H; I; J; K; L; M: string | FormulaNode](
  x: A = "",
  y: B = "",
  color: C = "",
  fill: D = "",
  shape: E = "",
  size: F = "",
  xMin: G = "",
  xMax: H = "",
  yMin: I = "",
  yMax: J = "",
  width: K = "",
  height: L = "",
  text: M = ""): Aesthetics =
    result = Aesthetics(x: x.orNoneScale(scLinearData, akX),
                        y: y.orNoneScale(scLinearData, akY),
                        color: color.orNoneScale(scColor),
                        fill: fill.orNoneScale(scFillColor),
                        shape: shape.orNoneScale(scShape),
                        size: size.orNoneScale(scSize),
                        xMin: xMin.orNoneScale(scLinearData, akX),
                        xMax: xMax.orNoneScale(scLinearData, akX),
                        yMin: yMin.orNoneScale(scLinearData, akY),
                        yMax: yMax.orNoneScale(scLinearData, akY),
                        width: width.orNoneScale(scLinearData, akX),
                        height: height.orNoneScale(scLinearData, akY),
                        # TODO: should we fix this axis here?... :| Use something
                        # other than `scLinearData`?
                        text: text.orNoneScale(scText),

func fillIds*(aes: Aesthetics, gids: set[uint16]): Aesthetics =
  result = aes
  template fillIt(arg: untyped): untyped =
    if arg.isSome:
      var val = arg.get
      val.ids = gids
      arg = some(val)
  fillIt(result.x)
  fillIt(result.y)
  fillIt(result.color)
  fillIt(result.fill)
  fillIt(result.size)
  fillIt(result.shape)
  fillIt(result.xMin)
  fillIt(result.xMax)
  fillIt(result.yMin)
  fillIt(result.yMax)

proc ggplot*[T](data: T, aes: Aesthetics = aes()): GgPlot[T] =
  result = GgPlot[T](data: data,
                     numXticks: 10,
                     numYticks: 10)
  #result.addAes aes
  result.aes = aes.fillIds({0'u16 .. high(uint16)})
  # TODO: fill others with defaults
  # add default theme
  result.theme = Theme(discreteScaleMargin: some(quant(0.2,
                                                       ukCentimeter)))

template assignBinFields(res: var Geom, stKind, bins,
                         binWidth, breaks: untyped): untyped =
  case stKind
  of stBin:
    if breaks.len > 0:
      res.binEdges = some(breaks)
    if binWidth > 0.0:
      res.binWidth = some(binWidth)
    if bins > 0:
      res.numBins = bins
  else: discard

func initGgStyle(color = none[Color](),
                 size = none[float](),
                 marker = none[MarkerKind](),
                 lineType = none[LineType](),
                 lineWidth = none[float](),
                 fillColor = none[Color](),
                 errorBarKind = none[ErrorBarKind](),
                 alpha = none[float](),
                 font = none[Font]()): GgStyle =
  result = GgStyle(color: color,
                   size: size,
                   marker: marker,
                   lineType: lineType,
                   lineWidth: lineWidth,
                   fillColor: fillColor,
                   errorBarKind: errorBarKind,
                   alpha: alpha,
                   font: font)

proc geom_point*(aes: Aesthetics = aes(),
                 data = DataFrame(),
                 color = none[Color](),
                 size = none[float](),
                 marker = none[MarkerKind](),
                 stat = "identity",
                 bins = -1,
                 binWidth = 0.0,
                 breaks: seq[float] = @[],
                 binPosition = "none",
                 position = "identity", # the position kind, "identity", "stack" etc.
                ): Geom =
  ## NOTE: When using a different position than `identity`, be careful reading the plot!
  ## If N classes are stacked and an intermediate class has no entries, it will be drawn
  ## on top of the previous value!
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let pKind = parseEnum[PositionKind](position)
  let style = initGgStyle(color = color, size = size, marker = marker)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkPoint,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind,
                position: pKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_errorbar*(aes: Aesthetics = aes(),
                    data = DataFrame(),
                    color = none[Color](),
                    size = none[float](),
                    lineType = none[LineType](),
                    stat = "identity",
                    bins = -1,
                    binWidth = 0.0,
                    breaks: seq[float] = @[],
                    binPosition = "none",
                    position = "identity", # the position kind, "identity", "stack" etc.
                   ): Geom =
  ## NOTE: When using a different position than `identity`, be careful reading the plot!
  ## If N classes are stacked and an intermediate class has no entries, it will be drawn
  ## on top of the previous value!
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let pKind = parseEnum[PositionKind](position)
  let style = initGgStyle(color = color, size = size, lineType = lineType,
                          errorBarKind = some(ebLinesT))
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkErrorBar,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind,
                position: pKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_linerange*(aes: Aesthetics = aes(),
                     data = DataFrame(),
                     color = none[Color](),
                     size = none[float](),
                     lineType = none[LineType](),
                     stat = "identity",
                     bins = -1,
                     binWidth = 0.0,
                     breaks: seq[float] = @[],
                     binPosition = "none",
                     position = "identity", # the position kind, "identity", "stack" etc.
                   ): Geom =
  ## NOTE: When using a different position than `identity`, be careful reading the plot!
  ## If N classes are stacked and an intermediate class has no entries, it will be drawn
  ## on top of the previous value!
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let pKind = parseEnum[PositionKind](position)
  let style = initGgStyle(color = color, size = size, lineType = lineType,
                          errorBarKind = some(ebLines))
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkErrorBar,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind,
                position: pKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)


proc geom_bar*(aes: Aesthetics = aes(),
               data = DataFrame(),
               color = none[Color](), # color of the bars
               alpha = none[float](),
               position = "stack",
               stat = "count",
              ): Geom =
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let pkKind = parseEnum[PositionKind](position)
  let stKind = parseEnum[StatKind](stat)
  let style = initGgStyle(lineType = some(ltSolid),
                          lineWidth = some(1.0), # draw 1 pt wide black line to avoid white pixels
                                                 # between bins at size of exactly 1.0 bin width
                          color = color,
                          fillColor = color,
                          alpha = alpha)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkBar,
                aes: aes.fillIds({gid}),
                userStyle: style,
                position: pkKind,
                binPosition: bpNone,
                statKind: stKind)

proc geom_line*(aes: Aesthetics = aes(),
                data = DataFrame(),
                color = none[Color](), # color of the line
                size = none[float](), # width of the line
                lineType = none[LineType](), # type of line
                fillColor = none[Color](),
                alpha = none[float](),
                stat = "identity",
                bins = -1,
                binWidth = 0.0,
                breaks: seq[float] = @[],
                binPosition = "none",
               ): Geom =
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let style = initGgStyle(color = color, lineWidth = size, lineType = lineType,
                          fillColor = fillColor, alpha = alpha)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkLine,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_histogram*(aes: Aesthetics = aes(),
                     data = DataFrame(),
                     binWidth = 0.0, bins = 30,
                     breaks: seq[float] = @[],
                     color = none[Color](), # color of the bars
                     alpha = none[float](),
                     position = "stack",
                     stat = "bin",
                     binPosition = "left",
                    ): Geom =
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let pkKind = parseEnum[PositionKind](position)
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let style = initGgStyle(lineType = some(ltSolid),
                          lineWidth = some(0.2), # draw 0.2 pt wide black line to avoid white pixels
                                                 # between bins at size of exactly 1.0 bin width
                          color = color, # default color
                          fillColor = color,
                          alpha = alpha)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkHistogram,
                aes: aes.fillIds({gid}),
                userStyle: style,
                position: pkKind,
                binPosition: bpKind,
                statKind: stKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_freqpoly*(aes: Aesthetics = aes(),
                    data = DataFrame(),
                    color = none[Color](), # color of the line
                    size = none[float](), # line width of the line
                    lineType = none[LineType](),
                    fillColor = none[Color](),
                    alpha = none[float](),
                    bins = 30,
                    binWidth = 0.0,
                    breaks: seq[float] = @[],
                    position = "identity",
                    stat = "bin",
                    binPosition = "center"
                   ): Geom =
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let pkKind = parseEnum[PositionKind](position)
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let style = initGgStyle(lineType = lineType,
                          lineWidth = size,
                          color = color,
                          fillColor = fillColor,
                          alpha = alpha)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkFreqPoly,
                aes: aes.fillIds({gid}),
                userStyle: style,
                position: pkKind,
                binPosition: bpKind,
                statKind: stKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_tile*(aes: Aesthetics = aes(),
                data = DataFrame(),
                color = none[Color](),
                fillColor = none[Color](),
                alpha = none[float](),
                size = none[float](),
                stat = "identity",
                bins = 30,
                binWidth = 0.0,
                breaks: seq[float] = @[],
                binPosition = "none",
                position = "identity", # the position kind, "identity", "stack" etc.
                ): Geom =
  ## NOTE: When using a different position than `identity`, be careful reading the plot!
  ## If N classes are stacked and an intermediate class has no entries, it will be drawn
  ## on top of the previous value!
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let pKind = parseEnum[PositionKind](position)
  let style = initGgStyle(color = color, fillColor = fillColor, size = size,
                          alpha = alpha)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkTile,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind,
                position: pKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)

proc geom_text*(aes: Aesthetics = aes(),
                data = DataFrame(),
                color = none[Color](),
                size = none[float](),
                marker = none[MarkerKind](),
                font = none[Font](),
                alignKind = taCenter,
                stat = "identity",
                bins = -1,
                binWidth = 0.0,
                breaks: seq[float] = @[],
                binPosition = "none",
                position = "identity", # the position kind, "identity", "stack" etc.
                ): Geom =
  ## NOTE: When using a different position than `identity`, be careful reading the plot!
  ## If N classes are stacked and an intermediate class has no entries, it will be drawn
  ## on top of the previous value!
  let dfOpt = if data.len > 0: some(data) else: none[DataFrame]()
  let stKind = parseEnum[StatKind](stat)
  let bpKind = parseEnum[BinPositionKind](binPosition)
  let pKind = parseEnum[PositionKind](position)
  let fontOpt = if font.isSome: font
                else: some(font(12.0, alignKind = alignKind))
  let style = initGgStyle(color = color, size = size,
                          marker = marker, font = fontOpt)
  let gid = incId()
  result = Geom(gid: gid,
                data: dfOpt,
                kind: gkText,
                userStyle: style,
                aes: aes.fillIds({gid}),
                binPosition: bpKind,
                statKind: stKind,
                position: pKind)
  assignBinFields(result, stKind, bins, binWidth, breaks)


proc facet_wrap*(fns: varargs[ FormulaNode]): Facet =
  result = Facet()
  for f in fns:
    doAssert f.kind == fkTerm
    doAssert f.rhs.val.kind == VString
    result.columns.add f.rhs.val.str

proc scale_x_log10*(): Scale =
  ## sets the X scale of the plot to a log10 scale
  result = Scale(col: f{""}, # will be filled when added to GgPlot obj
                 scKind: scTransformedData,
                 axKind: akX,
                 dcKind: dcContinuous,
                 trans: proc(v: Value): Value =
                            result = %~ log10(v.toFloat))

proc scale_y_log10*(): Scale =
  ## sets the Y scale of the plot to a log10 scale
  result = Scale(col: f{""}, # will be filled when added to GgPlot obj
                 scKind: scTransformedData,
                 axKind: akY,
                 dcKind: dcContinuous,
                 trans: proc(v: Value): Value =
                            result = %~ log10(v.toFloat))

func sec_axis*(trans: FormulaNode = nil, name: string = ""): SecondaryAxis =
  ## convenience proc to create a `SecondaryAxis`
  var fn: Option[FormulaNode]
  if not trans.isNil:
    fn = some(trans)
  result = SecondaryAxis(trans: fn,
                         name: name)

proc scale_x_continuous*(name: string = "",
                         secAxis: SecondaryAxis = sec_axis(),
                         dcKind: DiscreteKind = dcContinuous): Scale =
  ## creates a continuous x axis with a possible secondary axis.
  # NOTE: See note for y axis below
  var msecAxis: SecondaryAxis
  var secAxisOpt: Option[SecondaryAxis]
  if secAxis.name.len > 0:
    msecAxis = secAxis
    msecAxis.axKind = akX
    secAxisOpt = some(msecAxis)
  result = Scale(name: name,
                 scKind: scLinearData,
                 axKind: akX,
                 dcKind: dcKind,
                 hasDiscreteness: true,
                 secondaryAxis: secAxisOpt)

proc scale_y_continuous*(name: string = "",
                         secAxis: SecondaryAxis = sec_axis(),
                         dcKind: DiscreteKind = dcContinuous): Scale =
  ## creates a continuous y axis with a possible secondary axis.
  # NOTE: so far this only allows to set the name (read label) of the
  # axis. Also the possible transformation for the secondary axis
  # is ignored!
  var msecAxis: SecondaryAxis
  var secAxisOpt: Option[SecondaryAxis]
  if secAxis.name.len > 0:
    msecAxis = secAxis
    msecAxis.axKind = akY
    secAxisOpt = some(msecAxis)
  result = Scale(name: name,
                 scKind: scLinearData,
                 axKind: akY,
                 dcKind: dcKind,
                 hasDiscreteness: true,
                 secondaryAxis: secAxisOpt)

proc ggtitle*(title: string, subtitle = "",
              titleFont = font(), subTitleFont = font(8.0)): Theme =
  result = Theme(title: some(title))
  if subtitle.len > 0:
    result.subTitle = some(subTitle)
  if titleFont != font():
    result.titleFont = some(titleFont)
  if subTitleFont != font():
    result.subTitleFont = some(subTitleFont)

proc generateLegendMarkers(plt: Viewport, scale: Scale): seq[GraphObject]
proc genDiscreteLegend(view: var Viewport,
                       cat: Scale) =
  # TODO: add support for legend font in Theme / `let label` near botton!
  # _______________________
  # |   | Headline        |
  # |______________________
  # |1cm| 1cm |  | space  |
  # |   |grad.|.5| for    |
  # |   |     |cm| leg.   |
  # |   |     |  | labels |
  # -----------------------
  let markers = view.generateLegendMarkers(cat)
  let numElems = cat.valueMap.len
  view.layout(2, 2,
              colWidths = @[quant(0.5, ukCentimeter), # for space to plot
                            quant(0.0, ukRelative)], # for legend. incl header
              rowHeights = @[quant(1.0, ukCentimeter), # for header
                             quant(1.05 * numElems.float, ukCentimeter)]) # for act. legend
  var i = 0
  # now set the `height` according to the real legend height. This important
  # to get proper alignment of the scale / multiple scales in `finalizeLegend`!
  view.height = quant(1.0 + 1.05 * numElems.float, ukCentimeter)
  var leg = view[3]

  let rH = toSeq(0 ..< numElems).mapIt(quant(1.05, ukCentimeter))

  leg.layout(3, rows = numElems,
             colWidths = @[quant(1.0, ukCentimeter),
                           quant(0.3, ukCentimeter),
                           quant(0.0, ukRelative)],
             rowHeights = rH)
  # iterate only over added children, skip first, because we actual legend first
  var j = 0
  for i in countup(0, leg.children.len - 1, 3):
    # create rectangle showing style of data points
    var legBox = leg[i]
    var legLabel = leg[i + 2]
    #let viewRatio = ch.hView.val / ch.wView.val
    let style = Style(lineType: ltSolid,
                      lineWidth: 1.0,
                      color: color(1.0, 1.0, 1.0),
                      fillColor: grey92)
    let rect = legBox.initRect(Coord(x: c1(0.0),
                                     y: c1(0.0) + legBox.c1(0.025, akY, ukCentimeter)),
                               quant(1.0, ukCentimeter),
                               quant(1.0, ukCentimeter),
                               style = some(style),
                               name = "markerRectangle")
    # add marker ontop of rect
    ## TODO: choose marker type based on geom!
    let point = legBox.initPoint(Coord(x: c1(0.5),
                                       y: c1(0.5)),
                                 marker = markers[j].ptMarker,
                                 size = markers[j].ptSize,
                                 color = markers[j].ptColor,
                                 name = "markerPoint")
    var labelText = ""
    case cat.scKind
    of scColor, scFillColor, scShape, scSize:
      labelText = $cat.getLabelKey(j)
    else:
      raise newException(Exception, "`createLegend` unsupported for " & $cat.scKind)
    let label = legLabel.initText(
      Coord(
        x: c1(0.0),
        y: c1(0.5)),
      labelText,
      textKind = goText,
      alignKind = taLeft,
      name = "markerText"
    )
    legBox.addObj [rect, point]
    legLabel.addObj label
    leg[i] = legBox
    leg[i + 2] = legLabel
    inc j
  view[3] = leg

proc genContinuousLegend(view: var Viewport,
                         cat: Scale) =
  case cat.scKind
  of scSize:
    view.layout(1, rows = 5 + 1)
  of scColor, scFillColor:
    # create following legend layout
    # _______________________
    # |   | Headline        |
    # |______________________
    # |1cm| 1cm |  | space  |
    # |   |grad.|.5| for    |
    # |   |     |cm| leg.   |
    # |   |     |  | labels |
    # -----------------------
    view.layout(2, 2,
                colWidths = @[quant(0.5, ukCentimeter), # for space to plot
                              quant(0.0, ukRelative)], # for legend. incl header
                rowHeights = @[quant(1.0, ukCentimeter), # for header
                               quant(4.5, ukCentimeter)]) # for act. legend
    var legView = view[3]
    legView.yScale = cat.dataScale
    legView.layout(3, 1, colWidths = @[quant(1.0, ukCentimeter),
                                       quant(0.5, ukCentimeter),
                                       quant(0.0, ukRelative)])
    var legGrad = legView[0]
    # add markers
    let markers = legGrad.generateLegendMarkers(cat)
    legGrad.addObj markers
    let viridis = ViridisRaw.mapIt(color(it[0], it[1], it[2]))
    let cc = some(Gradient(colors: viridis))
    let gradRect = legGrad.initRect(c(0.0, 0.0),
                                    quant(1.0, ukRelative),
                                    quant(1.0, ukRelative),
                                    name = "legendGradientBackground",
                                    gradient = cc)
    legGrad.addObj gradRect
    legView[0] = legGrad
    view[3] = legView
    view.height = quant(5.5, ukCentimeter)
  else:
    discard

proc createLegend(view: var Viewport,
                  cat: Scale) =
  ## creates a full legend within the given viewport based on the categories
  ## in `cat` with a headline `title` showing data points of `markers`
  let startIdx = view.len
  case cat.dcKind
  of dcDiscrete:
    view.genDiscreteLegend(cat)
  of dcContinuous:
    # for now 5 sizes...
    view.genContinuousLegend(cat)

  # get the first viewport for the header
  if startIdx < view.len:
    var header = view[1]
    # TODO: add support to change font of legend
    var label = header.initText(
      Coord(x: c1(0.0),
            y: c1(0.5)),
      evaluate(cat.col).toStr,
      textKind = goText,
      alignKind = taLeft,
      name = "legendHeader")
    # set to bold
    label.txtFont.bold = true
    header.addObj label
    view[1] = header

proc finalizeLegend(view: var Viewport,
                    legends: seq[Viewport]) =
  ## finalizes the full legend from the given seq of legends
  ## such that the spacing between them is even
  # generate such layout
  # _________________
  # | relative space |
  # ------------------
  # | Legend 1       |
  # ------------------
  # | Legend 2       |
  # ------------------
  # ...
  # | relative space |
  # ------------------
  # calc number of spacings between legends
  var rowHeights = @[quant(0.0, ukRelative)]
  for i, l in legends:
    rowHeights.add l.height
  rowHeights.add quant(0.0, ukRelative)
  view.layout(1, rowHeights.len, rowHeights = rowHeights,
              ignoreOverflow = true)
  for i in countup(1, rowHeights.len - 2):
    var ml = legends[i - 1]
    ml.origin = view[i].origin
    view[i] = ml

proc legendPosition*(x = 0.0, y = 0.0): Theme =
  ## puts the legend at position `(x, y)` in relative coordinates of
  ## the plot viewport in range (0.0 .. 1.0)
  result = Theme(legendPosition: some(Coord(x: c1(x),
                                            y: c1(y))))

proc canvasColor*(color: Color): Theme =
  ## sets the canvas color of the plot to the given color
  result = Theme(canvasColor: some(color))

func theme_opaque*(): Theme =
  ## returns the "opaque" theme. For the time being this only means the
  ## canvas of the plot is white instead of transparent
  result = Theme(canvasColor: some(white))

func theme_void*(): Theme =
  ## returns the "void" theme. This means:
  ## - white background
  ## - no grid lines
  ## - no ticks
  ## - no tick labels
  ## - no labels
  result = Theme(canvasColor: some(white),
                 plotBackgroundColor: some(white),
                 hideTicks: some(true),
                 hideTickLabels: some(true),
                 hideLabels: some(true))

proc parseTextAlignString(alignTo: string): Option[TextAlignKind] =
  case alignTo.normalize
  of "none": result = none[TextAlignKind]()
  of "left": result = some(taLeft)
  of "right": result = some(taRight)
  of "center": result = some(taCenter)
  else: result = none[TextAlignKind]()

proc xlab*(label = "", margin = NaN, rotate = NaN,
           alignTo = "none", font = font(), tickFont = font()): Theme =
  if label.len > 0:
    result.xlabel = some(label)
  if classify(margin) != fcNaN:
    result.xlabelMargin = some(margin)
  if classify(rotate) != fcNaN:
    result.xTicksRotate = some(rotate)
  if font != font():
    result.labelFont = some(font)
  if tickFont != font():
    result.tickLabelFont = some(tickFont)
  result.xTicksTextAlign = parseTextAlignString(alignTo)

proc ylab*(label = "", margin = NaN, rotate = NaN,
           alignTo = "none", font = font(), tickFont = font()): Theme =
  if label.len > 0:
    result.ylabel = some(label)
  if classify(margin) != fcNaN:
    result.ylabelMargin = some(margin)
  if classify(rotate) != fcNaN:
    result.yTicksRotate = some(rotate)
  if font != font():
    result.labelFont = some(font)
  if tickFont != font():
    result.tickLabelFont = some(font)
  result.yTicksTextAlign = parseTextAlignString(alignTo)

func xlim*[T, U: SomeNumber](low: T, high: U, outsideRange = ""): Theme =
  ## Sets the limits of the plot range in data scale. This overrides the
  ## calculation of the data range, which by default is just
  ## `(min(dataX), max(dataX))` while ignoring `inf` values.
  ## If the given range is smaller than the actual underlying data range,
  ## `outsideRange` decides how data outside the range is treated.
  ##
  ## Supported values are `"clip"`, `"drop"` and `"none"`:
  ## - `"clip"`: clip all larger values (e.g. `inf` or all values larger than a
  ##   user defined `xlim`) to limit + xMargin (see below).
  ## - `"drop"`: remove all values larger than range
  ## - `"none"`: leave as is. Might result in values outside the plot area. Also `-inf`
  ##   values may be shown as large positive values. This is up to the drawing backend!
  ## It defaults to `"clip"`.
  ##
  ## Be aware however that the given limit is still subject to calculation of
  ## sensible tick values. The algorithm tries to make the plot start and end
  ## at "nice" values (either 1/10 or 1/4 steps). Setting the limit to some
  ## arbitrary number may not result in the expected plot. If a limit is to be
  ## forced, combine this with `xMargin`! (Note: if for some reason you want more
  ## control over the precise limits, please open an issue).
  ##
  ## NOTE: for a discrete axis the "data scale" is (0.0, 1.0). You can change
  ## it here, but it will probably result in an ugly plot!
  let orOpt = if outsideRange.len > 0: some(parseEnum[OutsideRangeKind](outsideRange))
              else: none[OutsideRangeKind]()
  result = Theme(xRange: some((low: low.float, high: high.float)),
                 xOutsideRange: orOpt)

func ylim*[T, U: SomeNumber](low: T, high: U, outsideRange = ""): Theme =
  ## Sets the limits of the plot range in data scale. This overrides the
  ## calculation of the data range, which by default is just
  ## `(min(dataY), max(dataY))` while ignoring `inf` values.
  ## If the given range is smaller than the actual underlying data range,
  ## `outsideRange` decides how data outside the range is treated.
  ##
  ## Supported values are `"clip"`, `"drop"` and `"none"`:
  ## - `"clip"`: clip all larger values (e.g. `inf` or all values larger than a
  ##   user defined `ylim`) to limit + yMargin (see below).
  ## - `"drop"`: remove all values larger than range
  ## - `"none"`: leave as is. Might result in values outside the plot area. Also `-inf`
  ##   values may be shown as large positive values. This is up to the drawing backend!
  ## It defaults to `"clip"`.
  ##
  ## Be aware however that the given limit is still subject to calculation of
  ## sensible tick values. The algorithm tries to make the plot start and end
  ## at "nice" values (either 1/10 or 1/4 steps). Setting the limit to some
  ## arbitrary number may not result in the expected plot. If a limit is to be
  ## forced, combine this with `yMargin`! (Note: if for some reason you want more
  ## control over the precise limits, please open an issue).
  ##
  ## NOTE: for a discrete axis the "data scale" is (0.0, 1.0). You can change
  ## it here, but it will probably result in an ugly plot!
  let orOpt = if outsideRange.len > 0: some(parseEnum[OutsideRangeKind](outsideRange))
              else: none[OutsideRangeKind]()
  result = Theme(yRange: some((low: low.float, high: high.float)),
                 yOutsideRange: orOpt)

proc xMargin*[T: SomeNumber](margin: T, outsideRange = ""): Theme =
  ## Sets a margin on the ``plot data scale`` for the X axis relative to the
  ## full data range. `margin = 0.05` extends the data range by 5 % of the
  ## difference of `xlim.high - xlim.low` (see `xlim` proc) on the left
  ## and right side.
  ## `outsideRange` determines the behavior of all points which lie outside the
  ## plot data range. If not set via `xlim` the plot data range is simply the
  ## full range of all x values, ignoring all `inf` values.
  ## Supported values are `"clip"`, `"drop"` and `"none"`:
  ## - `"clip"`: clip all larger values (e.g. `inf` or all values larger than a
  ##   user defined `xlim`) to limit + xMargin.
  ## - `"drop"`: remove all values larger than range
  ## - `"none"`: leave as is. Might result in values outside the plot area. Also `-inf`
  ##   values may be shown as large positive values. This is up to the drawing backend!
  ## It defaults to `"clip"`.
  ##
  ## NOTE: negative margins are not supported at the moment! They would result in
  ## ticks and labels outside the plot area.
  if margin.float < 0.0:
    raise newException(ValueError, "Margins must be positive! To make the plot " &
      "range smaller use `xlim`!")
  let orOpt = if outsideRange.len > 0: some(parseEnum[OutsideRangeKind](outsideRange))
              else: none[OutsideRangeKind]()
  result = Theme(xMargin: some(margin.float),
                 xOutsideRange: orOpt)

proc yMargin*[T: SomeNumber](margin: T, outsideRange = ""): Theme =
  ## Sets a margin on the ``plot data scale`` for the Y axis relative to the
  ## full data range. `margin = 0.05` extends the data range by 5 % of the
  ## difference of `ylim.high - ylim.low` (see `ylim` proc) on the top
  ## and bottom side.
  ## `outsideRange` determines the behavior of all points which lie outside the
  ## plot data range. If not set via `ylim` the plot data range is simply the
  ## full range of all y values, ignoring all `inf` values.
  ## Supported values are `"clip"`, `"drop"` and `"none"`:
  ## - `"clip"`: clip all larger values (e.g. `inf` or all values larger than a
  ##   user defined `ylim`) to limit + yMargin.
  ## - `"drop"`: remove all values larger than range
  ## - `"none"`: leave as is. Might result in values outside the plot area. Also `-inf`
  ##   values may be shown as large positive values. This is up to the drawing backend!
  ## It defaults to `"clip"`.
  ##
  ## NOTE: negative margins are not supported at the moment! They would result in
  ## ticks and labels outside the plot area.
  if margin.float < 0.0:
    raise newException(ValueError, "Margins must be positive! To make the plot " &
      "range smaller use `ylim`!")
  let orOpt = if outsideRange.len > 0: some(parseEnum[OutsideRangeKind](outsideRange))
              else: none[OutsideRangeKind]()
  result = Theme(yMargin: some(margin.float),
                 yOutsideRange: orOpt)

proc annotate*(text: string,
               left = NaN,
               bottom = NaN,
               x = NaN,
               y = NaN,
               font = font(12.0),
               backgroundColor = white): Annotation =
  ## creates an annotation of `text` with a background
  ## `backgroundColor` (by default white) using the given
  ## `font`. Line breaks are supported.
  ## It is placed either at:
  ## - `(left, bottom)`, where these correspond to relative coordinates
  ##   mapping out the plot area as (0.0, 1.0). NOTE: smaller and larger
  ##   values than 0.0 and 1.0 are supported and will put the annotation outside
  ##   the plot area.
  ## - `(x, y)` where `x` and `y` are values in the scale of the data
  ##   being plotted. This is useful if the annotation is to be placed relative
  ##   to specific data points. NOTE: for a discrete axis data scale is not
  ##   well defined, thus we fall back to relative scaling on that axis!
  ## In principle you can mix and match left/x and bottom/y! If both are given
  ## the former will be prioritized.
  result = Annotation(left: left.orNone,
                      bottom: bottom.orNone,
                      x: x.orNone,
                      y: y.orNone,
                      text: text,
                      font: font,
                      backgroundColor: backgroundColor)
  if result.x.isNone and result.left.isNone or
     result.y.isNone and result.bottom.isNone:
    raise newException(ValueError, "Both an x/left and y/bottom position has to " &
      "given to `annotate`!")

proc `+`*(p: GgPlot, geom: Geom): GgPlot =
  ## adds the given geometry to the GgPlot object
  result = p
  result.geoms.add geom

proc `+`*(p: GgPlot, facet: Facet): GgPlot =
  ## adds the given facet to the GgPlot object
  result = p
  result.facet = some(facet)

proc `+`*(p: GgPlot, aes: Aesthetics): GgPlot =
  ## adds the given aesthetics to the GgPlot object
  result = p
  # TODO: this is surely wrong and should be
  # `result.aes = aes`???
  result.aes = p

proc `+`*(p: GgPlot, annot: Annotation): GgPlot =
  ## adds the given Annotation to the GgPlot object
  result = p
  result.annotations.add annot

proc applyTheme(pltTheme: var Theme, theme: Theme) =
  ## applies all elements of `theme`, which are `Some` to
  ## the same fields of `pltTheme`
  template ifSome(it: untyped): untyped =
    if theme.it.isSome:
      pltTheme.it = theme.it
  ifSome(xlabelMargin)
  ifSome(ylabelMargin)
  ifSome(xLabel)
  ifSome(yLabel)
  ifSome(xTicksTextAlign)
  ifSome(yTicksTextAlign)
  ifSome(xTicksRotate)
  ifSome(yTicksRotate)
  ifSome(legendPosition)
  ifSome(labelFont)
  ifSome(tickLabelFont)
  ifSome(titleFont)
  ifSome(subTitleFont)
  ifSome(tickLabelFont)
  ifSome(title)
  ifSome(subTitle)
  ifSome(plotBackgroundColor)
  ifSome(canvasColor)
  ifSome(xRange)
  ifSome(yRange)
  ifSome(xMargin)
  ifSome(yMargin)
  ifSome(xOutsideRange)
  ifSome(yOutsideRange)
  ifSome(hideTicks)
  ifSome(hideTickLabels)
  ifSome(hideLabels)

proc `+`*(p: GgPlot, theme: Theme): GgPlot =
  ## adds the given theme (or theme element) to the GgPlot object
  result = p
  applyTheme(result.theme, theme)
  # TODO: Maybe move these two completely out of `GgPlot` object
  if result.theme.title.isSome:
    result.title = result.theme.title.get
  if result.theme.subTitle.isSome:
    result.subTitle = result.theme.subTitle.get

proc applyScale(aes: Aesthetics, scale: Scale): Aesthetics =
  ## applies the given `scale` to the `aes` by returning a modified
  ## `aes`
  var mscale = deepCopy(scale)
  result = aes
  case mscale.scKind
  of scLinearData, scTransformedData:
    # potentially `scale` has no `column` asigned yet, read from
    # `axKind` from the given `aes`. If `aes` has no `x`/`y` scale,
    # `mscale` will remain unchanged
    case scale.axKind
    of akX:
      if aes.x.isSome:
        mscale.col = aes.x.get.col
        mscale.ids = aes.x.get.ids
        result.x = some(mscale)
    of akY:
      if aes.y.isSome:
        mscale.col = aes.y.get.col
        mscale.ids = aes.y.get.ids
        result.y = some(mscale)
  of scColor:
    mscale.ids = aes.color.get.ids
    result.color = some(mscale)
  of scFillColor:
    mscale.ids = aes.fill.get.ids
    result.fill = some(mscale)
  of scSize:
    mscale.ids = aes.size.get.ids
    result.size = some(mscale)
  of scShape:
    mscale.ids = aes.shape.get.ids
    result.shape = some(mscale)
  of scText:
    mscale.ids = aes.text.get.ids
    result.text = some(mscale)

proc `+`*(p: GgPlot, scale: Scale): GgPlot =
  ## adds the given Scale to the GgPlot object.
  ## Overwrites
  result = p
  # Adding a scale requires to update the Scale of all existing
  # Aesthetics. Both of the plot and of its geoms. ggplot2 does the
  # inverse too. Adding a scale before another geom, still applies this
  # scale transformation to that geom...
  # scale_x_log10*() + geom_point(aes(x = "cty")) is considered the same as
  # geom_point(aes(x = "cty")) + scale_x_log10()
  # first apply to GgPlot aes:
  result.aes = applyScale(result.aes, scale)
  for p in mitems(result.geoms):
    p.aes = applyScale(p.aes, scale)

template anyScale(arg: untyped): untyped =
  if arg.main.isSome or arg.more.len > 0:
    true
  else:
    false

proc requiresLegend(filledScales: FilledScales): bool =
  ## returns true if the plot requires a legend to be drawn
  if anyScale(filledScales.color) or
     anyScale(filledScales.fill) or
     anyScale(filledScales.size) or
     anyScale(filledScales.shape):
    result = true
  else:
    result = false

proc plotLayoutWithLegend(view: var Viewport,
                          tightLayout = false) =
  ## creates a layout for a plot in the current viewport that leaves space
  ## for a legend. Important indices of the created viewports:
  ## If `tightLayout` is `true`, the left hand side will only have 0.2 cm
  ## of spacing.
  ## - main plot: idx = 4
  ## - legend: idx = 5
  # TODO: Make relative to image size!
  let leftSpace = if tightLayout: quant(0.2, ukCentimeter)
                  else: quant(2.5, ukCentimeter)
  view.layout(3, 3, colwidths = @[leftSpace,
                                  quant(0.0, ukRelative),
                                  quant(5.0, ukCentimeter)],
              rowheights = @[quant(1.25, ukCentimeter),
                             quant(0.0, ukRelative),
                             quant(2.0, ukCentimeter)])
  view[0].name = "topLeft"
  view[1].name = "title"
  view[2].name = "topRight"
  view[3].name = "yLabel"
  view[4].name = "plot"
  view[5].name = "legend"
  view[6].name = "bottomLeft"
  view[7].name = "xLabel"
  view[8].name = "bottomRight"

proc plotLayoutWithoutLegend(view: var Viewport,
                             tightLayout = false) =
  ## creates a layout for a plot in the current viewport without a legend
  ## If `tightLayout` is `true`, the left hand side will only have 0.2 cm
  ## of spacing.
  ## Main plot viewport will be:
  ## idx = 4
  let leftSpace = if tightLayout: quant(0.2, ukCentimeter)
                  else: quant(2.5, ukCentimeter)
  view.layout(3, 3, colwidths = @[leftSpace,
                                  quant(0.0, ukRelative),
                                  quant(1.0, ukCentimeter)],
              rowheights = @[quant(1.0, ukCentimeter),
                             quant(0.0, ukRelative),
                             quant(2.0, ukCentimeter)])
  view[0].name = "topLeft"
  view[1].name = "title"
  view[2].name = "topRight"
  view[3].name = "yLabel"
  view[4].name = "plot"
  view[5].name = "noLegend"
  view[6].name = "bottomLeft"
  view[7].name = "xLabel"
  view[8].name = "bottomRight"

macro genGetScale(field: untyped): untyped =
  let name = ident("get" & $field.strVal & "Scale")
  result = quote do:
    proc `name`(filledScales: FilledScales, geom = Geom(gid: 0)): Scale =
      result = new Scale
      if filledScales.`field`.main.isSome:
        # use main
        result = filledScales.`field`.main.get
      else:
        # find scale matching `gid`
        for s in filledScales.`field`.more:
          if geom.gid == 0 or geom.gid in s.ids:
            return s

genGetScale(x)
genGetScale(y)
# not used at the moment
#genGetScale(color)
#genGetScale(size)
#genGetScale(shape)
proc createLayout(view: var Viewport,
                  filledScales: FilledScales, theme: Theme) =
  let drawLegend = filledScales.requiresLegend
  let  hideTicks = if theme.hideTicks.isSome: theme.hideTicks.unsafeGet
                   else: false
  let hideTickLabels = if theme.hideTickLabels.isSome: theme.hideTickLabels.unsafeGet
                       else: false
  let hideLabels = if theme.hideLabels.isSome: theme.hideLabels.unsafeGet
                   else: false
  if drawLegend and not hideLabels and not hideTicks:
    view.plotLayoutWithLegend()
  elif drawLegend and hideLabels and hideTicks:
    view.plotLayoutWithLegend(tightLayout = true)
  elif not drawLegend and not hideLabels and not hideTicks:
    view.plotLayoutWithoutLegend()
  else:
    view.plotLayoutWithoutLegend(tightLayout = true)

proc generateLegendMarkers(plt: Viewport, scale: Scale): seq[GraphObject] =
  ## generate the required Legend Markers for the given `aes`
  ## TODO: add different objects to be shown depending on the scale and geom.
  ## E.g. in case of `fill` fill the whole rectangle with the color. In case
  ## of geom_line only draw a line etc.
  ## Thus also put the rectangle drawing here.
  # TODO: rewrite this either via a template, proc or macro!
  case scale.sckind
  of scColor, scFillColor:
    case scale.dcKind
    of dcDiscrete:
      for i in 0 ..< scale.valueMap.len:
        let color = scale.getValue(scale.getLabelKey(i)).color
        result.add initPoint(plt,
                             (0.0, 0.0), # dummy coordinates
                             marker = mkCircle,
                             color = color) # assign same marker as above
    of dcContinuous:
      # replace yScale by scale of `scale`
      var mplt = plt
      mplt.yScale = scale.dataScale
      # use 5 ticks by default
      # define as "secondary" because then ticks will be on the RHS
      let ticks = mplt.initTicks(akY, 5, boundScale = some(scale.dataScale),
                                 isSecondary = true)
      let tickLabs = mplt.tickLabels(ticks, isSecondary = true,
                                     margin = some(plt.c1(0.3, akX, ukCentimeter)))
      result = concat(tickLabs, ticks)
  of scShape:
    for i in 0 ..< scale.valueMap.len:
      result.add initPoint(plt,
                           (0.0, 0.0), # dummy coordinates
                           marker = scale.getValue(scale.getLabelKey(i)).marker)
  of scSize:
   for i in 0 ..< scale.valueMap.len:
     let size = scale.getValue(scale.getLabelKey(i)).size
     result.add initPoint(plt,
                          (0.0, 0.0), # dummy coordinates
                          marker = mkCircle,
                          size = size)
  else:
    raise newException(Exception, "`createLegend` unsupported for " & $scale.scKind)

# TODO: move this, remove one of the two (instead calc from the other)
# TODO2: use almostEqual from `formula` instead of this one here!!!
proc smallestPow(x: float): float =
  doAssert x > 0.0
  result = 1.0
  if x < 1.0:
    while result > x and not result.almostEqual(x):
      result /= 10.0
  else:
    while result < x and not result.almostEqual(x):
      result *= 10.0
    result /= 10.0

proc largestPow(x: float): float =
  doAssert x > 0.0
  result = 1.0
  if x < 1.0:
    while result > x and not result.almostEqual(x):
      result /= 10.0
    result *= 10.0
  else:
    while result < x and not result.almostEqual(x):
      result *= 10.0

proc tickposlog(minv, maxv: float,
                boundScale: ginger.Scale,
                hideTickLabels = false): (seq[string], seq[float]) =
  ## Calculates the positions and labels of a log10 data scale given
  ## a min and max value. Takes into account a final bound scale outside
  ## of which no ticks may lie.
  let numTicks = 10 * (log10(maxv) - log10(minv)).round.int
  var
    labs = newSeq[string]()
    labPos = newSeq[float]()
  for i in 0 ..< numTicks div 10:
    let base = (minv * pow(10, i.float))
    if not hideTickLabels:
      labs.add formatTickValue(base)
    let minors = linspace(base, 9 * base, 9)
    labPos.add minors.mapIt(it.log10)
    labs.add toSeq(0 ..< 8).mapIt("")
  if not hideTickLabels: labs.add $maxv
  else: labs.add ""
  labPos.add log10(maxv)
  # for simplicity apply removal afterwards
  let filterIdx = toSeq(0 ..< labPos.len).filterIt(
    labPos[it] >= boundScale.low and
    labPos[it] <= boundScale.high
  )
  # apply filters to `labs` and `labPos`
  labs = filterIdx.mapIt(labs[it])
  labPos = filterIdx.mapIt(labPos[it])
  result = (labs, labPos)

func getSecondaryAxis(filledScales: FilledScales, axKind: AxisKind): SecondaryAxis =
  ## Assumes a secondary axis must exist!
  case axKind
  of akX:
    let xScale = filledScales.getXScale()
    result = xScale.secondaryAxis.unwrap()
  of akY:
    let yScale = filledScales.getYScale()
    result = yScale.secondaryAxis.unwrap()

func hasSecondary(filledScales: FilledScales, axKind: AxisKind): bool =
  case axKind
  of akX:
    let xScale = filledScales.getXScale()
    if xScale.secondaryAxis.isSome:
      result = true
  of akY:
    let yScale = filledScales.getYScale()
    if yScale.secondaryAxis.isSome:
      result = true

func hasSecondary(theme: Theme, axKind: AxisKind): bool =
  case axKind
  of akX:
    if theme.xLabelSecondary.isSome:
      result = true
  of akY:
    if theme.yLabelSecondary.isSome:
      result = true

proc handleContinuousTicks(view: var Viewport, p: GgPlot, axKind: AxisKind,
                           scale: Scale, numTicks: int, theme: Theme,
                           isSecondary = false,
                           hideTickLabels = false): seq[GraphObject] =
  let boundScale = if axKind == akX: theme.xMarginRange else: theme.yMarginRange
  case scale.scKind
  of scLinearData:
    let ticks = view.initTicks(axKind, numTicks, isSecondary = isSecondary,
                               boundScale = some(boundScale))
    var tickLabs: seq[GraphObject]
    if not hideTickLabels:
      tickLabs = view.tickLabels(ticks, isSecondary = isSecondary,
                                 font = theme.tickLabelFont)
    view.addObj concat(ticks, tickLabs)
    result = ticks
  of scTransformedData:
    # for now assume log10 scale
    let minVal = pow(10, scale.dataScale.low).smallestPow
    let maxVal = pow(10, scale.dataScale.high).largestPow
    let (labs, labelpos) = tickposlog(minVal, maxVal, boundScale,
                                      hideTickLabels = hideTickLabels)
    var tickLocs: seq[Coord1D]
    case axKind
    of akX:
      tickLocs = labelpos.mapIt(Coord1D(pos: it,
                                        kind: ukData,
                                        scale: view.xScale,
                                        axis: akX))
      view.xScale = (low: log10(minVal), high: log10(maxVal))
    of akY:
      tickLocs = labelpos.mapIt(Coord1D(pos: it,
                                        kind: ukData,
                                        scale: view.yScale,
                                        axis: akY))
      view.yScale = (low: log10(minVal), high: log10(maxVal))

    let (tickObjs, labObjs) = view.tickLabels(tickLocs, labs, axKind, isSecondary = isSecondary,
                                              font = theme.tickLabelFont)
    view.addObj concat(tickObjs, labObjs)
    result = tickObjs
  else: discard

proc handleDiscreteTicks(view: var Viewport, p: GgPlot, axKind: AxisKind,
                         scale: Scale,
                         theme: Theme,
                         isSecondary = false,
                         hideTickLabels = false,
                         centerTicks = true): seq[GraphObject] =
  # create custom tick labels based on the possible labels
  # and assign tick locations based on ginger.Scale for
  # linear/trafo kinds and evenly spaced based on string?
  # start with even for all
  if isSecondary:
    raise newException(Exception, "Secondary axis for discrete axis not yet implemented!")
  let numTicks = scale.labelSeq.len
  var tickLabels: seq[string]
  var tickLocs: seq[Coord1D]
  let gScale = if scale.axKind == akX: view.xScale else: view.yScale

  # TODO: check if we should use w/hImg here, distinguish the axes
  let discrMarginOpt = p.theme.discreteScaleMargin
  var discrMargin = 0.0
  if discrMarginOpt.isSome:
    case axKind
    of akX: discrMargin = discrMarginOpt.unsafeGet.toRelative(length = some(pointWidth(view))).val
    of akY: discrMargin = discrMarginOpt.unsafeGet.toRelative(length = some(pointHeight(view))).val
  # NOTE: the following only holds if def. of `wview` changed in ginger
  # doAssert view.wview != view.wimg
  let barViewWidth = (1.0 - 2 * discrMargin) / numTicks.float
  var centerPos = barViewWidth / 2.0
  if not centerTicks:
    case axKind
    of akX: centerPos = 0.0
    of akY: centerPos = barViewWidth
  for i in 0 ..< numTicks:
    if not hideTickLabels: tickLabels.add $labelSeq[i]
    else: tickLabels.add ""
    # in case of a discrete scale we have categories, which are evenly spaced.
    # taking into account the margin of the plot, calculate center of all categories
    let pos = discrMargin + i.float * barViewWidth + centerPos
    let scale = (low: 0.0, high: 1.0)
    tickLocs.add Coord1D(pos: pos,
                         kind: ukRelative)
  var rotate: Option[float]
  var alignTo: Option[TextAlignKind]
  case axKind
  of akX:
    rotate = theme.xTicksRotate
    alignTo = theme.xTicksTextAlign
  of akY:
    rotate = theme.yTicksRotate
    alignTo = theme.yTicksTextAlign
  let (tickObjs, labObjs) = view.tickLabels(tickLocs, tickLabels, axKind, rotate = rotate,
                                            alignToOverride = alignTo,
                                            font = theme.tickLabelFont)
  view.addObj concat(tickObjs, labObjs)
  result = tickObjs

proc handleTicks(view: var Viewport, filledScales: FilledScales, p: GgPlot,
                 axKind: AxisKind, theme: Theme): seq[GraphObject] =
  ## This handles the creation of the tick positions and tick labels.
  ## It automatically updates the x and y scales of both the viewport and the `filledScales`!
  var scale: Scale
  var numTicks: int
  case axKind
  of akX:
    scale = filledScales.getXScale()
    numTicks = p.numXTicks
  of akY:
    scale = filledScales.getYScale()
    numTicks = p.numYTicks
  if not scale.col.isNil:
    case scale.dcKind
    of dcDiscrete:
      result = view.handleDiscreteTicks(p, axKind, scale, theme = theme)
      if hasSecondary(filledScales, axKind):
        let secAxis = filledScales.getSecondaryAxis(axKind)
        result.add view.handleDiscreteTicks(p, axKind, scale, theme = theme,
                                            isSecondary = true)
    of dcContinuous:
      result = view.handleContinuousTicks(p, axKind, scale, numTicks, theme = theme)
      if hasSecondary(filledScales, axKind):
        let secAxis = filledScales.getSecondaryAxis(axKind)
        result.add view.handleContinuousTicks(p, axKind, scale, numTicks, theme = theme,
                                              isSecondary = true,
                                              hideTickLabels = hideTickLabels)
  else:
    # this should mean the main geom is histogram like?
    doAssert axKind == akY, "we can have akX without scale now?"
    # in this case don't read into anything and just call ticks / labels
    let boundScale = if axKind == akX: theme.xMarginRange else: theme.yMarginRange
    let ticks = view.initTicks(axKind, numTicks, boundScale = some(boundScale))
    var tickLabs: seq[GraphObject]
    if hideTickLabels:
      tickLabs = view.tickLabels(ticks, font = theme.tickLabelFont)
    view.addObj concat(ticks, tickLabs)
    result = ticks

template argMaxIt(s, arg: untyped): untyped =
  ## `s` has to have a `pairs` iterator
  # TODO: move elsehere
  block:
    var
      maxVal = 0
      maxId = 0
    for i, it {.inject.} in s:
      if maxVal < arg:
        maxId = i
        maxVal = arg
    maxId

proc handleLabels(view: var Viewport, theme: Theme) =
  ## potentially moves the label positions and enlarges the areas (not yet)
  ## potentially moves the label positions and enlarges the areas (not yet)
  ## for the y label / tick label column or x row.
  # TODO: clean this up!
  var
    xLabObj: GraphObject
    yLabObj: GraphObject
    xMargin: Coord1D
    yMargin: Coord1D
  let
    xlabTxt = theme.xLabel.unwrap()
    ylabTxt = theme.yLabel.unwrap()
  template getMargin(marginVar, themeField, nameVal, axKind: untyped): untyped =
    if not themeField.isSome:
      let labs = view.objects.filterIt(it.name == nameVal)
      let labNames = labs.mapIt(it.txtText)
      let labLens = labNames.argMaxIt(len(it))
      # TODO: use custom label font for margin calc?
      let font = if theme.labelFont.isSome: theme.labelFont.get else: font(8.0)
      case axKind
      of akX:
        marginVar = Coord1D(pos: 1.1, kind: ukStrHeight,
                            text: labNames[labLens], font: font)
      of akY:
        marginVar = Coord1D(pos: 1.0, kind: ukStrWidth,
                            text: labNames[labLens], font: font) +
                    Coord1D(pos: 0.3, kind: ukCentimeter)

  template createLabel(label, labproc, labTxt, themeField, marginVal: untyped,
                       isSecond = false, rot = none[float]()): untyped =
    let fnt = if theme.labelFont.isSome: theme.labelFont.get else: font()
    if themeField.isSome:
      label = labproc(view,
                      labTxt,
                      margin = get(themeField),
                      isCustomMargin = true,
                      isSecondary = isSecond,
                      font = fnt)
    else:
      label = labproc(view,
                      labTxt,
                      margin = marginVal,
                      isSecondary = isSecond,
                      font = fnt)
  getMargin(xMargin, theme.xlabelMargin, "xtickLabel", akX)
  getMargin(yMargin, theme.ylabelMargin, "ytickLabel", akY)
  createLabel(yLabObj, ylabel, yLabTxt, theme.yLabelMargin, yMargin)
  createLabel(xLabObj, xlabel, xLabTxt, theme.xLabelMargin, xMargin)
  view.addObj @[xLabObj, yLabObj]

  if theme.hasSecondary(akX):
    let secAxisLabel = theme.xLabelSecondary.unwrap()
    var labSec: GraphObject
    createLabel(labSec, xlabel, secAxisLabel, theme.yLabelMargin, 0.0,
                true)
    view.addObj @[labSec]
  if theme.hasSecondary(akY):#p, akY):
    let secAxisLabel = theme.yLabelSecondary.unwrap()
    var labSec: GraphObject
    createLabel(labSec, ylabel, secAxisLabel, theme.yLabelMargin, 0.0,
                true)
    view.addObj @[labSec]

proc getPlotBackground(theme: Theme): Style =
  ## returns a suitable style (or applies default) for the background of
  ## the plot area
  result = Style(color: color(0.0, 0.0, 0.0, 0.0))
  if theme.plotBackgroundColor.isSome:
    result.fillColor = theme.plotBackgroundColor.unsafeGet
  else:
    # default color: `grey92`
    result.fillColor = grey92

proc getCanvasBackground(theme: Theme): Style =
  ## returns a suitable style (or applies default) for the background color of
  ## the whole plot canvas. By default it is transparent
  result = Style(color: transparent)
  if theme.canvasColor.isSome:
    result.fillColor = theme.canvasColor.unsafeGet
  else:
    # default background: transparent
    result.fillColor = transparent

proc generatePlot(view: Viewport, p: GgPlot, filledScales: FilledScales,
                  theme: Theme,
                  addLabels = true): Viewport =
  # first write all plots into dummy viewport
  result = view
  result.background(style = some(getPlotBackground(theme)))

  # change scales to user defined if desired
  result.xScale = if theme.xRange.isSome: theme.xRange.unsafeGet else: filledScales.xScale
  result.yScale = if theme.yRange.isSome: theme.yRange.unsafeGet else: filledScales.yScale

  for fg in filledScales.geoms:
    # for each geom, we create a child viewport of `result` covering
    # the whole resultport, which will house the data we just created.
    # Due to being a child, if will be drawn *after* its parent. This way things like
    # ticks will be below the data.
    # On the other hand this allows us to draw several geoms in on a plot and have the
    # order of the function calls `geom_*` be preserved
    var pChild = result.addViewport(name = "data")
    # DF here not needed anymore!
    pChild.createGobjFromGeom(fg, theme)
    # add the data viewport to the view
    result.children.add pChild

  var xticks = result.handleTicks(filledScales, p, akX, theme = theme)
  var yticks = result.handleTicks(filledScales, p, akY, theme = theme)

  # after creating all GraphObjects and determining tick positions based on
  # (possibly) user defined plot range, set the final range of the plot to
  # the range taking into account the given margin
  result.xScale = theme.xMarginRange
  result.yScale = theme.yMarginRange

  # TODO: Make sure we still have to do this. I think not!
  result.updateDataScale()

  result.updateDataScale(xticks)
  result.updateDataScale(yticks)
  let grdLines = result.initGridLines(some(xticks), some(yticks))

  # given the just created plot and tick labels, have to check
  # whether we should enlarge the column / row for the y / x label and
  # move the label
  if addLabels:
    # TODO: why do we add labels to child 4 and not directly into the viewport we
    # use to provide space for it, i.e. 3?
    result.handleLabels(theme)
  result.addObj @[grdLines]

proc generateFacetPlots(view: Viewport, p: GgPlot,
                        theme: Theme): Viewport =
  # first perform faceting by creating subgroups
  # doAssert p.facet.isSome
  # var mplt = p
  # mplt.data = p.data.group_by(p.facet.unsafeGet.columns)
  # result = view
  # var pltSeq: seq[Viewport]
  # for (pair, df) in groups(mplt.data):
  #   mplt = p
  #   mplt.data = df
  #   var viewFacet = result
  #   # add layout within `viewFacet` to accomodate the plot as well as the header
  #   viewFacet.layout(1, 2, rowHeights = @[quant(0.1, ukRelative), quant(0.9, ukRelative)],
  #                    margin = quant(0.01, ukRelative))
  #   var headerView = viewFacet[0]
  #   # set the background of the header
  #   headerView.background()
  #   # put in the text
  #   let text = pair.mapIt($it[0] & ": " & $it[1]).join(", ")
  #   let headerText = headerView.initText(c(0.5, 0.5),
  #                                        text,
  #                                        textKind = goText,
  #                                        alignKind = taCenter,
  #                                        name = "facetHeaderText")
  #   headerView.addObj headerText
  #   headerView.name = "facetHeader"
  #   var plotView = viewFacet[1]
  #   # now add dummy plt to pltSeq
  #   let filledScales = collectScales(mplt)
  #   plotView = plotView.generatePlot(mplt, filledScales, theme, hideLabels = true)
  #   plotView.name = "facetPlot"
  #   viewFacet[0] = headerView
  #   viewFacet[1] = plotView
  #   viewFacet.name = "facet_" & text
  #   pltSeq.add viewFacet
  #
  # # now create layout in `view`, the actual canvas for all plots
  # let (rows, cols) = calcRowsColumns(0, 0, pltSeq.len)
  # result.layout(cols, rows, margin = quant(0.02, ukRelative))
  # for i, plt in pltSeq:
  #   result.children[i].objects = plt.objects
  #   result.children[i].children = plt.children
  discard

proc customPosition(t: Theme): bool =
  ## returns true if `legendPosition` is set and thus legend sits at custom pos
  result = t.legendPosition.isSome

func labelName(filledScales: FilledScales, p: GgPlot, axKind: AxisKind): string =
  ## extracts the correct label for the given axis.
  ## First checks whether the theme sets a name, then checks the name of the
  ## x / y `Scale` and finally defaults to the column name.
  # doAssert p.aes.x.isSome, "x scale should exist?"
  case axKind
  of akX:
    let xScale = getXScale(filledScales)
    if xScale.name.len > 0:
      result = xScale.name
    else:
      result = $xScale.col
  of akY:
    let yScale = getYScale(filledScales)
    if yScale.name.len > 0:
      result = yScale.name
    elif not yScale.col.isNil:
      result = $yScale.col
    else:
      result = "count"

proc buildTheme*(filledScales: FilledScales, p: GgPlot): Theme =
  ## builds the final theme used for the plot. It takes the theme of the
  ## `GgPlot` object and fills in all missing fields as required from
  ## `filledScales` and `p`.
  result = p.theme
  if result.xLabel.isNone:
    result.xLabel = some(labelName(filledScales, p, akX))
  if result.yLabel.isNone:
    result.yLabel = some(labelName(filledScales, p, akY))
  if result.xLabelSecondary.isNone and filledScales.hasSecondary(akX):
    result.xLabelSecondary = some(filledScales.getSecondaryAxis(akX).name)
  if result.yLabelSecondary.isNone and filledScales.hasSecondary(akY):
    result.yLabelSecondary = some(filledScales.getSecondaryAxis(akY).name)

  # calculate `xMarginRange`, `yMarginRange` if any
  let xScale = if result.xRange.isSome: result.xRange.unsafeGet else: filledScales.xScale
  let xM = if result.xMargin.isSome: result.xMargin.unsafeGet else: 0.0
  let xdiff = xScale.high - xScale.low
  result.xMarginRange = (low: xScale.low - xdiff * xM,
                         high: xScale.high + xdiff * xM)
  let yScale = if result.yRange.isSome: result.yRange.unsafeGet else: filledScales.yScale
  let yM = if result.yMargin.isSome: result.yMargin.unsafeGet else: 0.0
  let ydiff = yScale.high - yScale.low
  result.yMarginRange = (low: yScale.low - ydiff * yM,
                         high: yScale.high + ydiff * yM)

proc getLeftBottom(view: Viewport, annot: Annotation): tuple[left: float, bottom: float] =
  ## Given an annotation this proc returns the relative `(left, bottom)`
  ## coordinates of either the `(x, y)` values in data space converted
  ## using the `x, y: ginger.Scale` of the viewport or directly using
  ## the annotations `(left, bottom)` pair if available
  if annot.left.isSome:
    result.left = annot.left.unsafeGet
  else:
    # NOTE: we make sure in during `annotate` that either `left` or
    # `x` is defined!
    result.left = toRelative(Coord1D(pos: annot.x.unsafeGet,
                                     kind: ukData,
                                     axis: akX,
                                     scale: view.xScale)).pos
  if annot.bottom.isSome:
    result.bottom = annot.bottom.unsafeGet
  else:
    # NOTE: we make sure in during `annotate` that either `bottom` or
    # `y` is defined!
    result.bottom = toRelative(Coord1D(pos: annot.y.unsafeGet,
                                       kind: ukData,
                                       axis: akY,
                                       scale: view.yScale)).pos


proc drawAnnotations*(view: var Viewport, p: GgPlot) =
  ## draws all annotations from `p` onto the mutable view `view`.
  # this is 0.5 times the string height. Margin between text and
  # the background rectangle
  const AnnotRectMargin = 0.5
  for annot in p.annotations:
    # style to use for this annotation
    let rectStyle = Style(fillColor: annot.backgroundColor,
                          color: annot.backgroundColor)
    let (left, bottom) = view.getLeftBottom(annot)
    ## TODO: Fix ginger calculations / figure out if / why cairo text extents
    # are bad in width direction
    let marginH = toRelative(strHeight(AnnotRectMargin, annot.font),
                            length = some(pointHeight(view)))
    let marginW = toRelative(strHeight(AnnotRectMargin, annot.font),
                            length = some(pointWidth(view)))
    let totalHeight = quant(
      toRelative(getStrHeight(annot.text, annot.font),
                 length = some(view.hView)).val +
      marginH.pos * 2.0,
      unit = ukRelative)
    # find longest line of annotation to base background on
    let maxLine = annot.text.strip.splitLines.sortedByIt(
      getStrWidth(it, annot.font).val
    )[^1]
    let maxWidth = getStrWidth(maxLine, annot.font)
    # calculate required width for background rectangle. string width +
    # 2 * margin
    let rectWidth = quant(
      toRelative(maxWidth, length = some(pointWidth(view))).val +
      marginW.pos * 2.0,
      unit = ukRelative
    )
    # left and bottom positions, shifted each by one margin
    let rectX = left - marginW.pos
    let rectY = bottom - totalHeight.toRelative(
      length = some(view.hView)
    ).val + marginH.pos
    # create background rectangle
    let annotRect = view.initRect(
      Coord(x: Coord1D(pos: rectX, kind: ukRelative),
            y: Coord1D(pos: rectY, kind: ukRelative)),
      rectWidth,
      totalHeight,
      style = some(rectStyle),
      name = "annotationBackground")
    # create actual annotation
    let annotText = view.initMultiLineText(
      origin = c(left, bottom),
      text = annot.text,
      textKind = goText,
      alignKind = taLeft,
      fontOpt = some(annot.font))
    view.addObj concat(@[annotRect], annotText)

proc ggcreate*(p: GgPlot, width = 640.0, height = 480.0): PlotView =
  ## applies all calculations to the `GgPlot` object required to draw
  ## the plot with cairo and returns a `PlotView`. The `PlotView` contains
  ## the final `Scales` built from the `GgPlot` object and all its geoms
  ## plus the ginal ginger.Viewport which only has to be drawn to produce the
  ## plot.
  ## This proc is useful to investigate the final Scales or the Viewport
  ## that will actually be drawn.
  let filledScales = collectScales(p)
  let theme = buildTheme(filledScales, p)
  # create the plot
  var img = initViewport(name = "root",
                         wImg = width,
                         hImg = height)

  # set color of canvas background
  img.background(style = some(getCanvasBackground(theme)))

  img.createLayout(filledScales, theme)
  # get viewport of plot
  var pltBase = img[4]

  if p.facet.isSome:
    pltBase = pltBase.generateFacetPlots(p, theme)
    # TODO :clean labels up, combine with handleLabels!
    # Have to consider what should happen for that though.
    # Need flag to disable auto subtraction, because we don't have space or
    # rather if done needs to be done on all subplots?
    let xlabel = pltBase.xlabel(theme.xLabel.unwrap())
    let ylabel = pltBase.ylabel(theme.yLabel.unwrap())
    pltBase.addObj @[xlabel, ylabel]
  else:
    pltBase = pltBase.generatePlot(p, filledScales, theme)
  let xScale = pltBase.xScale
  let yScale = pltBase.yScale
  img[4] = pltBase
  img.xScale = xScale
  img.yScale = yScale
  #img.updateDataScale()

  # possibly correct the yScale assigned to the root Viewport
  img.yScale = pltBase.yScale

  # draw legends
  # store each type of drawn legend. only one type for each kind
  var drawnLegends = initHashSet[(DiscreteKind, ScaleKind)]()
  var legends: seq[Viewport]
  for scale in enumerateScalesByIds(filledScales):
    if scale.scKind notin {scLinearData, scTransformedData} and
       (scale.dcKind, scale.scKind) notin drawnLegends:
      # handle color legend
      var lg = img[5]
      lg.createLegend(scale)
      legends.add lg
      drawnLegends.incl (scale.dcKind, scale.scKind)
  # now create final legend
  if legends.len > 0:
    img[5].finalizeLegend(legends)
    if customPosition(p.theme):
      let pos = p.theme.legendPosition.get
      img[5].origin.x = pos.x
      img[5].origin.y = pos.y

  # draw available annotations,
  img[4].drawAnnotations(p)

  if p.title.len > 0:
    var titleView = img[1]
    let font = if theme.titleFont.isSome: theme.titleFont.get else: font(16.0)
    let title = titleView.initText(c(0.0, 0.5),
                                   p.title,
                                   textKind = goText,
                                   alignKind = taLeft,
                                   font = some(font))
    titleView.addObj title
    img[1] = titleView

  result.filledScales = filledScales
  result.view = img

proc ggdraw*(view: Viewport, fname: string) =
  ## draws the given viewport and stores it in `fname`.
  ## It assumes that the `view` was created as the field of
  ## a `PlotView` object from a `GgPlot` object with `ggcreate`
  view.draw(fname)

proc ggdraw*(plt: PlotView, fname: string) =
  ## draws the viewport of the given `PlotView` and stores it in `fname`.
  ## It assumes that the `plt`` was created from a `GgPlot` object with
  ## `ggcreate`
  plt.view.draw(fname)

proc ggsave*(p: GgPlot, fname: string, width = 640.0, height = 480.0) =
  let plt = p.ggcreate(width = width, height = height)
  plt.view.ggdraw(fname)

proc ggsave*(fname: string, width = 640.0, height = 480.0): Draw =
  Draw(fname: fname,
       width: some(width),
       height: some(height))

proc `+`*(p: GgPlot, d: Draw) =
  if d.width.isSome and d.height.isSome:
    p.ggsave(d.fname,
             width = d.width.get,
             height = d.height.get)
  else:
    p.ggsave(d.fname)

proc ggvega*(): VegaDraw = VegaDraw()

from json import nil
proc `+`*(p: GgPlot, d: VegaDraw): json.JsonNode =
  p.toVegaLite()

proc countLines(s: var FileStream): int =
  ## quickly counts the number of lines and then resets stream to beginning
  ## of file
  var buf = newString(500)
  while s.readLine(buf):
    inc result
  s.setPosition(0)

proc checkHeader(s: Stream, fname, header: string, colNames: seq[string]): bool =
  ## checks whether the given file contains the header `header`
  result = true
  if header.len > 0:
    var headerBuf: string
    if s.peekLine(headerBuf):
      result = headerBuf.startsWith(header)
    else:
      raise newException(IOError, "The input file " & $fname & " seems to be empty.")
  elif colNames.len > 0:
    # given some column names and a "header" without a symbol means we assume
    # there is no real header. If there is a real header in addition, user has
    # to use `skipLines = N` to skip it.
    result = false

proc readCsv*(s: Stream,
              sep = ',',
              header = "",
              skipLines = 0,
              colNames: seq[string] = @[],
              fname = "<unknown>"): OrderedTable[string, seq[string]] =
  ## returns a `Stream` with CSV like data as a table of `header` keys vs. `seq[string]`
  ## values, where idx 0 corresponds to the first data value
  ## The `header` field can be used to designate the symbol used to
  ## differentiate the `header`. By default `#`.
  ## `colNames` can be used to provide custom names for the columns.
  ## If any are given and a header is present with a character indiciating
  ## the header, it is automatically skipped. ``However``, if custom names are
  ## desired and there is a real header without any starting symbol (i.e.
  ## `header.len == 0`), please use `skipLines = N` to skip it manually!
  # first check if the file even has a header of type `header`
  let hasHeader = checkHeader(s, fname, header, colNames)

  var parser: CsvParser
  open(parser, s, fname, separator = sep, skipInitialSpace = true)

  if colNames.len > 0:
    # if `colNames` available, use as header
    parser.headers = colNames
    if hasHeader:
      # and skip the real header
      discard parser.readRow()
  elif hasHeader:
    # read the header and use it
    parser.readHeaderRow()
  else:
    # file has no header nor user gave column names, raise
    raise newException(IOError, "Input neither has header starting with " &
      $header & " nor were column names provided!")

  result = initOrderedTable[string, seq[string]]()
  # filter out the header, delimiter, if any
  parser.headers.keepItIf(it != header)

  # possibly strip the headers and create the result table of columns
  var colHeaders: seq[string]
  for colUnstripped in items(parser.headers):
    let col = colUnstripped.strip
    colHeaders.add col
    result[col] = newSeqOfCap[string](5000) # start with a reasonable default cap

  # parse the actual file using the headers
  var lnCount = 0
  while readRow(parser):
    if lnCount < skipLines:
      inc lnCount
      continue
    for i, col in parser.headers:
      parser.rowEntry(col).removePrefix({' '})
      parser.rowEntry(col).removeSuffix({' '})
      result[colHeaders[i]].add parser.rowEntry(col)
  parser.close()

proc readCsv*(fname: string,
              sep = ',',
              header = "",
              skipLines = 0,
              colNames: seq[string] = @[]): OrderedTable[string, seq[string]] =
  ## returns a CSV file as a table of `header` keys vs. `seq[string]`
  ## values, where idx 0 corresponds to the first data value
  ## The `header` field can be used to designate the symbol used to
  ## differentiate the `header`. By default `#`.
  ## `colNames` can be used to provide custom names for the columns.
  ## If any are given and a header is present with a character indiciating
  ## the header, it is automatically skipped. ``However``, if custom names are
  ## desired and there is a real header without any starting symbol (i.e.
  ## `header.len == 0`), please use `skipLines = N` to skip it manually!
  var s = newFileStream(fname, fmRead)
  if s == nil:
    raise newException(IOError, "Input file " & $fname & " does not exist! " &
     "`readCsv` failed.")
  result = s.readCsv(sep, header, skipLines, colNames, fname = fname)
  s.close()

proc writeCsv*(df: DataFrame, filename: string, sep = ',', header = "",
               precision = 4) =
  ## writes a DataFrame to a "CSV" (separator can be changed) file.
  ## `sep` is the actual separator to be used. `header` indicates a potential
  ## symbol marking the header line, e.g. `#`
  var data = newStringOfCap(df.len * 8) # for some reserved space
  # add header symbol to first line
  data.add header
  let keys = getKeys(df)
  data.add join(keys, $sep) & "\n"
  var idx = 0
  for row in df:
    idx = 0
    for x in row:
      if idx > 0:
        data.add $sep
      data.add pretty(x, precision = precision)
      inc idx
    data.add "\n"
  writeFile(filename, data)
