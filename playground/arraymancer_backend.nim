#import ggplotnim

#[
In principle we could support an arraymancer backend. By changing the `DataFrame`
type as:
]#
#type
#  DataFrameAr* = object
#    len*: int
#    columns*: Table[string, int] # table mapping the column key to an integer
#    data*: Tensor[Value]
#    case kind: DataFrameKind
#    of dfGrouped:
#      # a grouped data frame stores the keys of the groups and maps them to
#      # a set of the categories
#      groupMap: OrderedTable[string, HashSet[Value]]
#    else: discard
#[
And providing overloads for the access of the data frame this should work fine
]#

#proc `[]`(df: DataFrameAr, key: string): Tensor[Value] =
#  ## returns a column of the data frame
#  ## Or maybe this should just return a single column data frame
#  result = df.data[df.columns[key], _]

#[
The `DataFrame` tensor should probably be `column` major, so that accessing a column
is quick. For most operations looking at the whole column is required. Row access is
not needed so much?
]#


# maybe instead

import macros, tables, strutils, options, fenv, sets, hashes, sugar

import sequtils, stats, strformat, algorithm, parseutils

# for error messages to print types
import typetraits

from ginger import Scale

import arraymancer
export arraymancer

import df_io
export df_io

import value
export value

import column
export column

import formulaClosure
export formulaClosure

type
  FormulaKind = enum
    fkNone, fkVector, fkScalar, fkVariable

  FormulaNode* = object
    name*: string
    case kind*: FormulaKind
    of fkNone: discard
    # just some constant value. Result of a simple computation as a `Value`
    # This is mainly used to rename columns / provide a constant value
    of fkVariable: val*: Value
    of fkVector:
      resType*: ColKind
      fnV*: proc(df: DataFrame): Column
      #case dtKindV*: ColKind
      #of colFloat: fnFloatV*: proc(df: DataFrame): float
      #of colInt: fnIntV*: proc(df: DataFrame): int
      #of colString: fnStringV*: proc(df: DataFrame): string
      #of colBool: fnBoolV*: proc(df: DataFrame): bool
      #of colObject: fnValueV*: proc(df: DataFrame): Value
    of fkScalar:
      valKind*: ValueKind
      fnS*: proc(c: DataFrame): Value
      #case dtKindS: ColKind
      #of cFloat: fnFloatS: proc(x: float): float
      #of cInt: fnIntS: proc(x: int): int
      #of cString: fnStringS: proc(x: string): string
      #of cBool: fnBoolS: proc(x: bool): bool
      #of cObject: fnValueS: proc(x: Value): Value

  DataFrameKind = enum
    dfNormal, dfGrouped

  # where value is as usual
  # then
  DataFrame* = object
    len*: int
    data*: Table[string, Column]
    case kind: DataFrameKind
    of dfGrouped:
      # a grouped data frame stores the keys of the groups and maps them to
      # a set of the categories
      groupMap: OrderedTable[string, HashSet[Value]]
    else: discard

const ValueNull* = Value(kind: VNull)

#proc initVariable*[T](x: T): FormulaNode[T] =
#  result = FormulaNode[T](kind: fkVariable,
#                          val: x)

#proc evaluate*(node: FormulaNode): Value
#proc evaluate*(node: FormulaNode, data: DataFrame, idx: int): Value
#proc reduce*(node: FormulaNode, data: DataFrame): Value
#proc evaluate*(node: FormulaNode, data: DataFrame): PersistentVector[Value]
#

func initDataFrame*(): DataFrame =
  result.data = initTable[string, Column](16) # default 16 columns

func `high`*(df: DataFrame): int = df.len - 1

iterator keys*(df: DataFrame): string =
  for k in keys(df.data):
    yield k

proc getKeys*[T](tab: OrderedTable[string, T]): seq[string] =
  ## returns the keys of the table as a seq
  for k in keys(tab):
    result.add k

proc getKeys*(df: DataFrame): seq[string] =
  ## returns the keys of a data frame as a seq
  for k in keys(df):
    result.add k

#iterator mpairs*(df: var DataFrame): (string, var PersistentVector[Value]) =
#  for k, mval in mpairs(df.data):
#    yield (k, mval)
#
proc drop*(df: var DataFrame, key: string) {.inline.} =
  ## drops the given key from the DataFrame
  df.data.del(key)

#proc add*(v: PersistentVector[Value], w: PersistentVector[Value]): PersistentVector[Value] =
#  ## adds all elements of `w` to `v` and returns the resulting vector
#  if v.len > 100 or w.len > 100:
#    # go the seq conversion route
#    var res = toSeq(v)
#    res.add toSeq(w)
#    result = toPersistentVector(res)
#  else:
#    result = v
#    for x in w:
#      result = result.add x

proc contains*(df: DataFrame, key: string): bool =
  ## Contains proc for `DataFrames`, which checks if the `key` names
  ## a column in the `DataFrame`
  result = df.data.hasKey(key)

proc `[]`*(df: DataFrame, k: string): Column {.inline.} =
  result = df.data[k]

proc `[]`*(df: DataFrame, k: string, idx: int): Value {.inline.} =
  ## returns the element at index `idx` in column `k` directly, without
  ## returning the whole vector first
  result = df.data[k][idx, Value]

proc `[]`*[T](df: DataFrame, k: string, slice: Slice[int], dtype: typedesc[T]): Tensor[T] {.inline.} =
  ## returns the elements in `slice` in column `k` directly, without
  ## returning the whole vector first as a tensor of type `dtype`
  result = df.data[k][slice.a .. slice.b, dtype]

proc `[]`*(df: DataFrame, k: string, slice: Slice[int]): Column {.inline.} =
  ## returns the elements in `slice` in column `k` directly, without
  ## returning the whole vector first
  result = df.data[k][slice.a .. slice.b]

proc `[]=`*(df: var DataFrame, k: string, vec: Column) {.inline.} =
  df.data[k] = vec

proc `[]=`*[T](df: var DataFrame, k: string, idx: int, val: T) {.inline.} =
  ## WARNING: only use this if you know that `T` is the correct data type!
  when T is float:
    df.data[k].fcol[idx] = val
  elif T is int:
    df.data[k].icol[idx] = val
  elif T is string:
    df.data[k].scol[idx] = val
  elif T is bool:
    df.data[k].bcol[idx] = val
  elif T is Value:
    df.data[k].ocol[idx] = val

proc get*(df: DataFrame, key: string): Column {.inline.} =
  if key in df:
    result = df[key]
  else:
    # create column of constants or raise?
    raise newException(KeyError, "Given string " & $key & " is not a valid column!")

proc reorderRawTilde(n: NimNode, tilde: NimNode): NimNode =
  ## a helper proc to reorder an nnkInfix tree according to the
  ## `~` contained in it, so that `~` is at the top tree.
  ## (the actual result is simply the tree reordered, but without
  ## the tilde. Reassembly must happen outside this proc)
  result = copyNimTree(n)
  for i, ch in n:
    case ch.kind
    of nnkIdent, nnkStrLit, nnkIntLit .. nnkFloat64Lit, nnkPar, nnkCall:
      discard
    of nnkInfix:
      if ch == tilde:
        result[i] = tilde[2]
      else:
        result[i] = reorderRawTilde(ch, tilde)
    else:
      error("Unsupported kind " & $ch.kind)

proc recurseFind(n: NimNode, cond: NimNode): NimNode =
  ## a helper proc to find a node matching `cond` recursively
  for i, ch in n:
    if ch == cond:
      result = n
      break
    else:
      let found = recurseFind(ch, cond)
      if found.kind != nnkNilLIt:
        result = found

proc replaceColumns(body: NimNode, idents: var seq[NimNode],
                    fkKind: FormulaKind): NimNode =
  result = copyNimTree(body)
  # essentially we have to do the following:
  # - replace all strings by calls to `df["String"]`
  #   how do we determine if something should be a call?
  #   use `get` proc, which returns string as value if not a
  #   valid column? Or raise in that case?
  # - determine the resulting data type of the proc. How?
  #   If arithmetic:
  #   - +, -, *, /, mod
  #   in formula body, then it's float
  #   elif and, or, xor, not in body, then it's bool
  #   else string?
  for i in 0 ..< body.len:
    case body[i].kind
    of nnkAccQuoted: #nnkStrLit:
      case fkKind
      of fkVector:
        let idIdx = ident"idx"
        result[i] = nnkBracketExpr.newTree(idents.pop,
                                           idIdx)
        #nnkCall.newTree(ident"get", ident"df", body[i])
      of fkScalar:
        # just the full column
        # TODO: change such that we determine which ident needs to be
        # scalar treated and which vector, based on determining
        # the formula kind the way we do in default backend!
        result[i] = idents.pop
      else: discard
    else:
      result[i] = replaceColumns(body[i], idents, fkKind = fkKind)

proc collectColumns(body: NimNode): seq[NimNode] =
  result = newSeq[NimNode]()
  for i in 0 ..< body.len:
    case body[i].kind
    of nnkAccQuoted: #StrLit:
      result.add body[i][0].toStrLit
    else:
      result.add collectColumns(body[i])

proc compileVectorFormula(name, body, dtype, resDtype: NimNode): NimNode =
  let columns = collectColumns(body)
  var idents = newSeq[NimNode]()
  for i, c in columns:
    idents.add genSym(nskVar, ident = "col" & $c)
  var colDefs = nnkVarSection.newTree()
  for i, c in idents:
    let rhs = nnkCall.newTree(ident"toTensor",
                              nnkBracketExpr.newTree(ident"df",
                                                     columns[i]),
                              dtype)
    colDefs.add nnkIdentDefs.newTree(
      idents[i],
      newEmptyNode(),
      rhs)
  # now add `res` tensor
  var resSym = genSym(nskVar, ident = "res")
  let dfIdent = ident"df"
  colDefs.add nnkIdentDefs.newTree(
    resSym,
    newEmptyNode(),
    nnkCall.newTree(nnkBracketExpr.newTree(ident"newTensor",
                                           resDtype),
                    nnkDotExpr.newTree(dfIdent,
                                       ident"len"))
  )
  let idIdx = ident"idx"
  # reverse the idents, since we use `pop`
  idents.reverse()
  let forLoopBody = replaceColumns(body, idents, fkKind = fkVector)
  let resultId = ident"result"

  let bodyFinal = quote do:
    `colDefs`
    for `idIdx` in 0 ..< `dfIdent`.len:
      `resSym`[`idIdx`] = `forLoopBody`
    `resultId` = toColumn `resSym`
  # given columns
  let containsDfAccess = true
  var procImpl: NimNode
  if containsDfAccess:
    let params = [ident"Column",
                  nnkIdentDefs.newTree(ident"df",
                                       ident"DataFrame",
                                       newEmptyNode())]
    procImpl = newProc(newEmptyNode(),
                       params = params,
                       body = bodyFinal,
                       procType = nnkLambda)
  result = quote do:
    FormulaNode(name: `name`, kind: fkVector,
                resType: toColKind(`dtype`),
                fnV: `procImpl`)
  echo result.repr

proc compileScalarFormula(name, body, dtype, resDtype: NimNode): NimNode =
  let columns = collectColumns(body)
  var idents = newSeq[NimNode]()
  for i, c in columns:
    idents.add genSym(nskVar, ident = "col" & $c)
  var colDefs = nnkVarSection.newTree()
  for i, c in idents:
    let rhs = nnkCall.newTree(ident"toTensor",
                              nnkBracketExpr.newTree(ident"df",
                                                     columns[i]),
                              dtype)
    colDefs.add nnkIdentDefs.newTree(
      idents[i],
      newEmptyNode(),
      rhs)
  # now add `res` tensor
  var resSym = genSym(nskVar, ident = "res")
  let dfIdent = ident"df"
  colDefs.add nnkIdentDefs.newTree(
    resSym,
    resDtype,
    newEmptyNode())
  let idIdx = ident"idx"
  # reverse the idents, since we use `pop`
  idents.reverse()
  let scalarBody = replaceColumns(body, idents, fkKind = fkScalar)
  let resultId = ident"result"

  let bodyFinal = quote do:
    `colDefs`
    `resSym` = `scalarBody`
    `resultId` = %~ (`resSym`)
  # given columns
  let containsDfAccess = true
  var procImpl: NimNode
  if containsDfAccess:
    let params = [ident"Value",
                  nnkIdentDefs.newTree(ident"df",
                                       ident"DataFrame",
                                       newEmptyNode())]
    procImpl = newProc(newEmptyNode(),
                       params = params,
                       body = bodyFinal,
                       procType = nnkLambda)
  result = quote do:
    FormulaNode(name: `name`, kind: fkScalar,
                valKind: toValKind(`dtype`),
                fnS: `procImpl`)
  echo result.repr

proc checkDtype(body: NimNode,
                floatSet: HashSet[string],
                stringSet: HashSet[string],
                boolSet: HashSet[string]):
                  tuple[isFloat: bool,
                        isString: bool,
                        isBool: bool] =
  for i in 0 ..< body.len:
    case body[i].kind
    of nnkIdent:
      # check
      result = (isFloat: body[i].strVal in floatSet,
                isString: body[i].strVal in stringSet,
                isBool: body[i].strVal in boolSet)
    of nnkStrLit .. nnkTripleStrLit:
      result.isString = true
    of nnkIntLit .. nnkFloat64Lit:
      result.isFloat = true
    else:
      let res = checkDtype(body[i], floatSet, stringSet, boolSet)
      result = (isFloat: result.isFloat or res.isFloat,
                isString: result.isString or res.isString,
                isBool: result.isBool or res.isBool)

func determineFormulaKind(body: NimNode): FormulaKind =
  result = fkNone
  for i in 0 ..< body.len:
    case body[i].kind
    of nnkAccQuoted: #nnkStrLit .. nnkTripleStrLit:
      # assume this refers to a column, so vector
      # (how to diff scalar?)
      result = fkVector
    of nnkIntLit .. nnkFloat64Lit:
      if result != fkVector:
        # if already a vector, leave it
        result = fkVariable
    else:
      let res = determineFormulaKind(body[i])
      result = if res != fkNone: res else: result

func determineFuncKind(body: NimNode,
                       typeHint: NimNode):
     tuple[dtype: NimNode,
           resDtype: NimNode,
           fkKind: FormulaKind] =
  ## checks for certain ... to  determine both the probable
  ## data type for a computation and the `FormulaKind`
  if body.len == 0:
    # a literal or an identifier
    case body.kind
    of nnkIdent:
      result = (newNilLit(), # unknown type since untyped macro
                newNilLit(),
                fkVariable)
    of nnkIntLit .. nnkUInt64Lit:
      result = (ident"int",
                ident"int",
                fkVariable)
    of nnkFloatLit .. nnkFloat64Lit:
      result = (ident"float",
                ident"float",
                fkVariable)
    of nnkCharLit, nnkStrLit .. nnkTripleStrLit:
      result = (ident"string",
                ident"string",
                fkVariable)
    else:
      doAssert false, "Weird kind: " & $body.kind & " for body " & $body.repr
  else:
    # if more than one element, have to be a bit smarter about it
    # we use the following heuristics
    # - if `+, -, *, /, mod` involved, return as `float`
    #   `TODO:` can we somehow leave pure `int` calcs as `int`?
    # - if `&`, `$` involved, result is string
    # - if `and`, `or`, `xor`, `>`, `<`, `>=`, `<=`, `==`, `!=` involved
    #   result is considered `bool`
    # The priority of these is,
    # - 1. bool
    # - 2. string
    # - 3. float
    # which allows for something like
    # `"10." & "5" == $(val + 0.5)` as a valid bool expression
    # walk tree and check for symbols
    const floatSet = toSet(@["+", "-", "*", "/", "mod"])
    const stringSet = toSet(@["&", "$"])
    const boolSet = toSet(@["and", "or", "xor", ">", "<", ">=", "<=", "==", "!=", "true", "false"])
    let (isFloat, isString, isBool) = checkDtype(body, floatSet, stringSet, boolSet)
    debugecho "IS FLOAT ", isFloat
    debugecho "IS string ", isstring
    debugecho "IS bool ", isbool
    if isFloat:
      result[0] = ident"float"
      result[1] = ident"float"
    if isString:
      # overrides float if it appears
      result[0] = ident"string"
      result[1] = ident"string"
    if isBool:
      # overrides float and string if it appears
      if isString:
        result[0] = ident"string"
      elif isFloat:
        result[0] = ident"float"
      else:
        # is bool tensor
        result[0] = ident"bool"
      # result is definitely bool
      result[1] = ident"bool"

    # apply typeHint if available (overrides above)
    if typeHint.kind != nnkNilLit:
      if isBool:
        # we don't override bool result type.
        # in cases like:
        # `f{int: x > 4}` the are sure of the result, apply to col only
        result[0] = typeHint
      elif isFloat or isString:
        # override dtype, result still clear
        result[0] = typeHint
      else:
        # set both
        result[0] = typeHint
        result[1] = typeHint

    # finally determine the FormulaKind
    # TODO: for now we just assume that raw string literals are supposed
    # to refer to columns. We will provide a different macro entry to
    # explicitly refer to non DF related formulas
    # TODO2: we might want to consider
    result[2] = determineFormulaKind(body)

proc compileFormulaImpl(name, body: NimNode,
                        isAssignment: bool,
                        isReduce: bool,
                        typeHint: NimNode): NimNode =
  var (dtype, resDtype, funcKind) = determineFuncKind(body, typeHint = typeHint)
  # force `fkVariable` if this is an `<-` assignment
  funcKind = if isAssignment: fkVariable
             elif isReduce: fkScalar
             else: funcKind
  case funcKind
  of fkNone:
    discard
  of fkVariable:
    result = quote do:
      FormulaNode(kind: fkVariable,
                  name: `name`,
                  val: %~ `body`)
  of fkVector:
    result = compileVectorFormula(name, body, dtype, resDtype)
  else:
    result = compileScalarFormula(name, body, dtype, resDtype)

proc compileFormula(n: NimNode): NimNode =
  var isAssignment = false
  var isReduce = false
  var typeHint = newNilLit()
  let tilde = recurseFind(n,
                          cond = ident"~")
  var node = n
  var formulaName: NimNode
  var formulaRhs: NimNode
  if tilde.kind != nnkNilLit and n[0].ident != toNimIdent"~":
    # only reorder the tree, if it does contain a tilde and the
    # tree is not already ordered (i.e. nnkInfix at top with tilde as
    # LHS)
    let replaced = reorderRawTilde(n, tilde)
    let full = nnkInfix.newTree(tilde[0],
                                tilde[1],
                                replaced)
    node = full
    formulaName = node[1]
  if tilde.kind == nnkNilLit:
    # extract possible type hint
    case node.kind
    of nnkExprColonExpr:
      echo "?? @ ",  node.repr
      typeHint = node[0]
      node = copyNimTree(node[1])
      echo node.repr
    else: discard # no type hint
    # check for `<-` assignment
    if eqIdent(node[0], ident"<-"):
      # this is an assignment `w/o` access of DF column
      doAssert node[1].kind == nnkAccQuoted
      formulaName = node[1][0].toStrLit
      formulaRhs = node[2]
      isAssignment = true
    elif eqIdent(node[0], ident"<<"):
      # this is an assignment `w/o` access of DF column
      doAssert node[1].kind == nnkAccQuoted
      formulaName = node[1][0].toStrLit
      formulaRhs = node[2]
      isReduce = true
    else:
      let name = buildFormula(node)
      formulaName = quote do:
        $(`name`)
      formulaRhs = node
  else:
    formulaName = node[1]
    formulaRhs = node[2]
  result = compileFormulaImpl(formulaName, formulaRhs,
                              isAssignment = isAssignment,
                              isReduce = isReduce,
                              typeHint = typeHint)

macro `{}`*(x: untyped{ident}, y: untyped): untyped =
  ## TODO: add some ability to explicitly create formulas of
  ## different kinds more easily! Essentially force the type without
  ## a check to avoid having to rely on heuristics.
  ## Use
  ## - `<-` for assignment
  ## - maybe `<<` for reduce operations, i.e. scalar proc?
  if x.strVal == "f":
    result = compileFormula(y)

#proc `[]=`*[T](df: var DataFrame, k: string, data: openArray[T]) {.inline.} =
#  ## Extends the given DataFrame by the column `k` with the `data`.
#  ## This proc raises if the given data length if not the same as the
#  ## DataFrames' length. In case `k` already exists, `data` will override
#  ## the current content!
#  if data.len == df.len:
#    df.data[k] = toPersistentVector(%~ data)
#  else:
#    raise newException(ValueError, "Given `data` length of " & $data.len &
#      " does not match DF length of: " & $df.len & "!")
#
#proc `[]=`*(df: var DataFrame, k: string, idx: int, val: Value) {.inline.} =
#  df.data[k] = df.data[k].update(idx, val)

template `^^`(df, i: untyped): untyped =
  (when i is BackwardsIndex: df.len - int(i) else: int(i))

proc `[]`*[T, U](df: DataFrame, rowSlice: HSlice[T, U]): DataFrame =
  ## returns the vertical slice of the data frame given by `rowSlice`.
  result = DataFrame(len: 0)
  let a = (df ^^ rowSlice.a)
  let b = (df ^^ rowSlice.b)
  for k in keys(df):
    result[k] = df[k, a .. b]
  # add 1, because it's an ``inclusive`` slice!
  result.len = (b - a) + 1

proc row*(df: DataFrame, idx: int, cols: varargs[string]): Value {.inline.} =
  ## Returns the row `idx` of the DataFrame `df` as a `Value` of kind `VObject`.
  ## If `cols` are given, only those columns will appear in the resulting `Value`.
  result = newVObject(length = cols.len)
  let mcols = if cols.len == 0: getKeys(df) else: @cols
  for col in mcols:
    result[col] = df[col][idx, Value]

#template `[]`*(df: DataFrame, idx: int): Value =
#  ## convenience template around `row` to access the `idx`-th row of the
#  ## DF as a `VObject Value`.
#  df.row(idx)
#
#func isColumn*(fn: FormulaNode, df: DataFrame): bool =
#  case fn.kind
#  of fkVariable:
#    case fn.val.kind
#    of VString: result = fn.val.str in df
#    else: result = false
#  else: result = false
#
#template `failed?`(cond: untyped): untyped {.used.} =
#  # helper template
#  debugecho "Failed? ", astToStr(cond), ": ", cond
#
proc pretty*(df: DataFrame, numLines = 20, precision = 4, header = true): string =
  ## converts the first `numLines` to a table.
  ## If the `numLines` argument is negative, will print all rows of the
  ## dataframe.
  ## The precision argument is relevant for `VFloat` values, but can also be
  ## (mis-) used to set the column width, e.g. to show long string columns.
  ## The `header` is the `Dataframe with ...` information line, which is not part
  ## of the returned values for simplicity if the output is to be assigned to some
  ## variable. TODO: we could change that (current way makes a test case easier...)
  ## TODO: need to improve printing of string columns if length of elements
  ## more than `alignBy`.
  var maxLen = 6 # default width for a column name
  for k in keys(df):
    maxLen = max(k.len, maxLen)
  if header:
    echo "Dataframe with ", df.getKeys.len, " columns and ", df.len, " rows:"
  let alignBy = max(maxLen + precision, 10)
  let num = if numLines > 0: min(df.len, numLines) else: df.len
  # write header
  result.add align("Idx", alignBy)
  for k in keys(df):
    result.add align($k, alignBy)
  result.add "\n"
  for i in 0 ..< num:
    result.add align($i, alignBy)
    for k in keys(df):
      let element = pretty(df[k, i], precision = precision)
      if element.len < alignBy - 1:
        result.add align(element,
                         alignBy)
      else:
        result.add align(element[0 ..< alignBy - 4] & "...",
                         alignBy)
    result.add "\n"

template `$`*(df: DataFrame): string = df.pretty

proc extendShortColumns*(df: var DataFrame) =
  ## initial calls to `seqsToDf` and other procs may result in a ragged DF, which
  ## has less entries in certain columns than the data frame length.
  ## This proc fills up the mutable dataframe in those columns
  for k in keys(df):
    if df[k].len < df.len:
      let nFill = df.len - df[k].len
      df[k] = df[k].add nullColumn(nFill)

proc toDf*(t: OrderedTable[string, seq[string]]): DataFrame =
  ## creates a data frame from a table of seq[string]
  ## NOTE: This proc assumes that the given entries in the `seq[string]`
  ## have been cleaned of white space. The `readCsv` proc takes care of
  ## this.
  ## TODO: currently does not allow to parse bool!
  result = DataFrame(len: 0)
  for k, v in t:
    var col: Column
    # check first element of v for type
    if v.len > 0:
      # TODO: CLEAN UP
      var maybeNumber = v[0].isNumber
      var maybeInt = v[0].isInt
      if maybeNumber and maybeInt:
        # try as int
        try:
          let data = v.mapIt(it.parseInt)
          col = data.toColumn
        except ValueError:
          try:
            let data = v.mapIt(it.parseFloat)
            col = data.toColumn
          except ValueError:
            # then parse as value
            var data = newSeq[Value](v.len)
            for i, x in v:
              try:
                data[i] = %~ x.parseInt
              except ValueError:
                try:
                  data[i] = %~ x.parseFloat
                except ValueError:
                  data[i] = %~ x
      elif maybeNumber:
        try:
          let data = v.mapIt(it.parseFloat)
          col = data.toColumn
        except ValueError:
          # then parse as value
          var data = newSeq[Value](v.len)
          for i, x in v:
            try:
              data[i] = %~ x.parseFloat
            except ValueError:
              data[i] = %~ x
      else:
        # try bool?
        try:
          let data = v.mapIt(it.parseBool)
          col = v.toColumn
        except ValueError:
          col = v.toColumn
    result.data[k] = col
    result.len = max(result.data[k].len, result.len)
  result.extendShortColumns()

proc toDf*(t: OrderedTable[string, seq[Value]]): DataFrame =
  ## creates a data frame from a table of `seq[Value]`. Simply have to convert
  ## the `seq[Value]` to a `PersistentVector[Value]` and add to DF.
  result = DataFrame(len: 0)
  for k, v in t:
    result[k] = v.toColumn
    result.len = max(v.len, result.len)
  result.extendShortColumns()

macro toTab*(args: varargs[untyped]): untyped =
  expectKind(args, nnkArglist)
  var s = args
  if args.len == 1 and args[0].kind == nnkTableConstr:
    # has to be tableConstr or simple ident
    s = args[0]
  elif args.len == 1 and args[0].kind notin {nnkIdent, nnkSym}:
    error("If only single argument it has to be an ident or symbol, " &
      "but " & $args[0].repr & " is of kind: " & $args[0].kind)
  let data = ident"columns"
  result = newStmtList()
  result.add quote do:
    var `data` = initDataFrame()
  for a in s:
    case a.kind
    of nnkIdent:
      let key = a.strVal
      result.add quote do:
        `data`[`key`] = `a`.toColumn
        `data`.len = max(`data`.len, `a`.len)
    of nnkExprColonExpr:
      let nameCh = a[0]
      let seqCh = a[1]
      result.add quote do:
        `data`[`nameCh`] = `seqCh`.toColumn
        `data`.len = max(`data`.len, `seqCh`.len)
    else:
      error("Unsupported kind " & $a.kind)
  result = quote do:
    block:
      `result`
      # finally fill up possible columns shorter than df.len
      #`data`.extendShortColumns()
      `data`
  echo result.treerepr
  echo result.repr

template seqsToDf*(s: varargs[untyped]): untyped =
  ## converts an arbitrary number of sequences to a `DataFrame` or any
  ## number of key / value pairs where we have string / seq[T] pairs.
  toTab(s)

proc hasKey(df: DataFrame, key: string): bool =
  result = df.data.hasKey(key)

iterator items*(df: DataFrame): Value =
  # returns each row of the dataframe as a Value of kind VObject
  for i in 0 ..< df.len:
    yield df.row(i)

#iterator pairs*(df: DataFrame): (int, Value) =
#  # returns each row of the dataframe as a Value of kind VObject
#  for i in 0 ..< df.len:
#    yield (i, df.row(i))
#
#proc toSeq(v: PersistentVector[Value]): seq[Value] =
#  result = v[0 ..< v.len]
#
#proc toSeq(df: DataFrame, key: string): seq[Value] =
#  result = df[key].toSeq
#
#proc vToSeq*(v: PersistentVector[Value]): seq[Value] = toSeq(v)
#proc vToSeq*(df: DataFrame, key: string): seq[Value] = toSeq(df, key)
#
#proc toFloat*(s: string): float =
#  # TODO: replace by `toFloat(v: Value)`!
#  result = s.parseFloat
#
#proc nearlyEqual(x, y: float, eps = 1e-10): bool =
#  ## equality check for floats which tries to work around floating point
#  ## errors
#  ## Taken from: https://floating-point-gui.de/errors/comparison/
#  let absX = abs(x)
#  let absY = abs(y)
#  let diff = abs(x - y)
#  if x == y:
#    # shortcut, handles infinities
#    result = true
#  elif x == 0 or
#       y == 0 or
#       diff < minimumPositiveValue(system.float):
#    # a or b is zero or both are extremely close to it
#    # relative error is less meaningful here
#    result =  diff < (eps * minimumPositiveValue(system.float))
#  else:
#    # use relative error
#    result = diff / min((absX + absY), maximumPositiveValue(system.float)) < eps
#
#proc isValidVal(v: Value, f: FormulaNode): bool =
#  doAssert v.kind != VObject
#  doAssert f.kind == fkTerm
#  doAssert f.op in {amEqual, amGreater, amLess, amGeq, amLeq, amAnd, amOr, amXor}
#  case v.kind
#  of VInt, VFloat:
#    case f.op
#    of amEqual:
#      result = v.toFloat.nearlyEqual(f.rhs.val.toFloat)
#    of amUnequal:
#      result = not v.toFloat.nearlyEqual(f.rhs.val.toFloat)
#    of amGreater:
#      result = v > f.rhs.val
#    of amLess:
#      result = v < f.rhs.val
#    of amGeq:
#      result = v >= f.rhs.val
#    of amLeq:
#      result = v <= f.rhs.val
#    else:
#      raise newException(Exception, "comparison of kind " & $f.op & " does " &
#        "not make sense for value kind of " & $v.kind & "!")
#  of VString:
#    doAssert not f.rhs.val.isNumber, "comparison must be with another string!"
#    case f.op
#    of amEqual:
#      result = v == f.rhs.val
#    of amUnequal:
#      result = v != f.rhs.val
#    of amGreater:
#      result = v > f.rhs.val
#    of amLess:
#      result = v < f.rhs.val
#    else:
#      raise newException(Exception, "comparison of kind " & $f.op & " does " &
#        "not make sense for value kind of " & $v.kind & "!")
#  of VBool:
#    doAssert f.rhs.val.kind == VBool, "comparison must be with another bool!"
#    case f.op
#    of amEqual:
#      result = v == f.rhs.val
#    of amUnequal:
#      result = v != f.rhs.val
#    of amGreater:
#      result = v > f.rhs.val
#    of amLess:
#      result = v < f.rhs.val
#    of amGeq:
#      result = v >= f.rhs.val
#    of amLeq:
#      result = v <= f.rhs.val
#    of amAnd:
#      result = v.toBool and f.rhs.val.toBool
#    of amOr:
#      result = v.toBool or f.rhs.val.toBool
#    of amXor:
#      result = v.toBool xor f.rhs.val.toBool
#    else:
#      raise newException(Exception, "comparison of kind " & $f.op & " does " &
#        "not make sense for value kind of " & $v.kind & "!")
#  else:
#    raise newException(Exception, "comparison for kind " & $v.kind &
#      " not yet implemented!")
#
#proc isValidRow(v: Value, f: FormulaNode): bool =
#  doAssert v.kind == VObject
#  doAssert f.kind == fkTerm
#  doAssert f.op in {amEqual, amUnequal, amGreater, amLess, amGeq, amLeq}
#  let lhsKey = f.lhs.val
#  doAssert f.lhs.val.kind == VString
#  result = v[lhsKey.str].isValidVal(f)
#
#proc delete(df: DataFrame, rowIdx: int): DataFrame =
#  result = df
#  for k in keys(df):
#    var s = df[k][0 ..< df.len]
#    s.delete(rowIdx)
#    #result[k] = s
#    result[k] = toPersistentVector(s)
#  result.len = result.len - 1

#proc add(df: var DataFrame, row: Value) =
#  for k in keys(row):
#    if not df.hasKey(k):
#      df[k] = initColumn(toColKind(row[k]))
#    df[k] = df[k].add row[k]
#    doAssert df.len + 1 == df[k].len
#  df.len = df.len + 1

#proc getFilteredIdx(df: DataFrame, cond: FormulaNode): seq[int] =
#  ## return indices allowed after filter, by applying `cond` to each index
#  ## and checking it's validity
#  result = newSeqOfCap[int](df.len)
#  var mcond = cond
#  for i in 0 ..< df.len:
#    if mcond.evaluate(df, i).toBool:
#      result.add i
#
#proc getFilteredIdx(idx: seq[int], df: DataFrame, cond: FormulaNode): seq[int] =
#  ## return indices allowed after filter, starting from a given sequence
#  ## of allowed indices
#  result = newSeqOfCap[int](idx.len)
#  var mcond = cond
#  for i in idx:
#    if mcond.evaluate(df, i).toBool:
#      result.add i
#
#func filter(p: PersistentVector[Value], idx: seq[int]): PersistentVector[Value] =
#  result = toPersistentVector(idx.mapIt(p[it]))

#func filter(p: seq[Value], idx: seq[int]): seq[Value] =
#  result = idx.mapIt(p[it])

#template withKind(col: Column, body: untyped): untyped =
#  case col.kind
#  of colFloat:
#    let t {.inject.} = toTensor(col, float)
#    var res {.inject.} = newTensor[float](nonZero)
#    body
#  of colInt:
#    let t {.inject.} = toTensor(col, int)
#    var res {.inject.} = newTensor[int](nonZero)
#    body
#  of colString:
#    let t {.inject.} = toTensor(col, string)
#    var res {.inject.} = newTensor[string](nonZero)
#    body
#  of colBool:
#    let t {.inject.} = toTensor(col, bool)
#    var res {.inject.} = newTensor[bool](nonZero)
#    body
#  of colObject:
#    let t {.inject.} = toTensor(col, Value)
#    var res {.inject.} = newTensor[Value](nonZero)
#    body

func filter(col: Column, filterIdx: Tensor[int]): Column =
  ## perform filterting of the given column `key`
  withNativeDtype(col):
    let t = toTensor(col, dtype)
    var res = newTensor[dtype](filterIdx.size)
    if filterIdx.size > 0:
      for i, idx in filterIdx:
        res[i[0]] = t[idx]
    result = res.toColumn

func countTrue(t: Tensor[bool]): int {.inline.} =
  for el in t:
    if el:
      inc result

func filteredIdx(t: Tensor[bool]): Tensor[int] {.inline.} =
  let numNonZero = countTrue(t)
  result = newTensor[int](numNonZero)
  var idx = 0
  for i, cond in t:
    if cond:
      result[idx] = i[0]
      inc idx

proc filter*(df: DataFrame, conds: varargs[FormulaNode]): DataFrame =
  ## returns the data frame filtered by the conditions given
  var fullCondition: FormulaNode
  var filterIdx: Column
  for c in conds:
    if filterIdx.len > 0:
      # combine two tensors
      let newIdx = c.fnV(df)
      # `filterIdx` must be `bool`
      assert filterIdx.kind == colBool
      filterIdx.bCol.apply2_inline(newIdx.bCol):
        # calculate logic and
        x and y
    else:
      # eval boolean function on DF
      filterIdx = c.fnV(df)
  let nonZeroIdx = filteredIdx(filterIdx.bCol)
  for k in keys(df):
    result[k] = df[k].filter(nonZeroIdx)
    # fill each key with the non zero elements
  result.len = nonZeroIdx.size
#template liftVectorFloatProc*(name: untyped,
#                              toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `seq[float]` to act on a `PersistentVector[Value]`
#  ## so that it can be used in a formula to act on a whole DF column.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: PersistentVector[Value]): Value =
#      result = Value(kind: VFloat, fnum: `name`(v[0 ..< v.len].mapIt(it.toFloat)))
#  else:
#    proc `name`(v: PersistentVector[Value]): Value =
#      result = Value(kind: VFloat, fnum: `name`(v[0 ..< v.len].mapIt(it.toFloat)))
#
#template liftVectorIntProc*(name: untyped,
#                            toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `seq[int]` to act on a `PersistentVector[Value]`
#  ## so that it can be used in a formula to act on a whole DF column.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: PersistentVector[Value]): Value =
#      result = Value(kind: VInt, num: `name`(v[0 ..< v.len].mapIt(it.toInt)))
#  else:
#    proc `name`(v: PersistentVector[Value]): Value =
#      result = Value(kind: VInt, num: `name`(v[0 ..< v.len].mapIt(it.toInt)))
#
#template liftVectorStringProc*(name: untyped,
#                               toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `seq[string]` to act on a `PersistentVector[Value]`
#  ## so that it can be used in a formula to act on a whole DF column.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: PersistentVector[Value]): Value =
#      result = Value(kind: VString, str: `name`(v[0 ..< v.len].mapIt(it.toStr)))
#  else:
#    proc `name`(v: PersistentVector[Value]): Value =
#      result = Value(kind: VString, str: `name`(v[0 ..< v.len].mapIt(it.toStr)))
#
#template liftScalarFloatProc*(name: untyped,
#                              toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `float` to act on a `Value`
#  ## so that it can be used in a formula to act on an element in a DF.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: Value): Value =
#      result = %~ `name`(v.toFloat)
#  else:
#    proc `name`(v: Value): Value =
#      result = %~ `name`(v.toFloat)
#
#template liftScalarIntProc*(name: untyped,
#                           toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `int` to act on a `Value`
#  ## so that it can be used in a formula to act on an element in a DF.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: Value): Value =
#      result = %~ `name`(v.toInt)
#  else:
#    proc `name`(v: Value): Value =
#      result = %~ `name`(v.toInt)
#
#template liftScalarStringProc*(name: untyped,
#                               toExport: static bool = true): untyped =
#  ## Lifts a proc, which takes a `string` to act on a `Value`
#  ## so that it can be used in a formula to act on an element in a DF.
#  ## `toExport` can be set to `false` so that the resulting proc is not exported.
#  ## This is useful to lift procs only locally (e.g. in a test case etc.)
#  when toExport:
#    proc `name`*(v: Value): Value =
#      result = %~ `name`(v.toStr)
#  else:
#    proc `name`(v: Value): Value =
#      result = %~ `name`(v.toStr)
#
#proc length*(v: PersistentVector[Value]): Value =
#  ## returns the `length` of the given vector (DF column) as a `Value`.
#  ## Essentially just a working version of `len` for use in formulas, e.g.
#  ## for `summarize`. Does not use the `len` name for two reasons:
#  ## 1. Nim does not allow overload by return type
#  ## 2. `length` is the name in R
#  result = %~ v.len
#
#proc colMin*(s: seq[Value], ignoreInf = true): float =
#  ## Returns the minimum of a given `seq[Value]`.
#  ## If `ignoreInf` is true `-Inf` values are ignored. This porc
#  ## is mainly used to determine the data scales for a plot and not
#  ## as a user facing proc!
#  for i, x in s:
#    let xFloat = x.toFloat
#    if i == 0:
#      result = xFloat
#    if ignoreInf and classify(xFloat) == fcNegInf:
#      continue
#    result = min(xFloat, result)
#
#proc colMin*(df: DataFrame, col: string, ignoreInf = true): float =
#  ## Returns the minimum of a DF column.
#  ## If `ignoreInf` is true `-Inf` values are ignored. This porc
#  ## is mainly used to determine the data scales for a plot and not
#  ## as a user facing proc!
#  let colVals = df[col].vToSeq
#  result = colVals.colMin(ignoreInf = ignoreInf)
#
#proc colMax*(s: seq[Value], ignoreInf = true): float =
#  ## Returns the maximum of a given string`seq[Value]`.
#  ## If `ignoreInf` is true `Inf` values are ignored. This proc
#  ## is mainly used to determine the data scales for a plot and not
#  ## as a user facing proc!
#  for i, x in s:
#    let xFloat = x.toFloat
#    if i == 0:
#      result = xFloat
#    if ignoreInf and classify(xFloat) == fcInf:
#      continue
#    result = max(xFloat, result)
#
#proc colMax*(df: DataFrame, col: string, ignoreInf = true): float =
#  ## Returns the maximum of a DF column.
#  ## If `ignoreInf` is true `Inf` values are ignored. This proc
#  ## is mainly used to determine the data scales for a plot and not
#  ## as a user facing proc!
#  let colVals = df[col].vToSeq
#  result = colVals.colMax(ignoreInf = ignoreInf)
#
#func scaleFromData*(s: seq[Value], ignoreInf: static bool = true): ginger.Scale =
#  ## Combination of `colMin`, `colMax` to avoid running over the data
#  ## twice. For large DFs to plot this makes a big difference.
#  if s.len == 0: return (low: 0.0, high: 0.0)
#  var
#    xFloat = s[0].toFloat
#    minVal = xFloat
#    maxVal = xFloat
#  for i, x in s:
#    xFloat = x.toFloat
#    when ignoreInf:
#      if (classify(xFloat) == fcNegInf or
#          classify(xFloat) == fcInf):
#        continue
#    minVal = min(xFloat, minVal)
#    maxVal = max(xFloat, maxVal)
#  result = (low: minVal, high: maxVal)
#
#liftVectorFloatProc(mean)
#liftVectorFloatProc(sum)
#liftScalarFloatProc(abs)
#liftVectorFloatProc(min)
#liftVectorFloatProc(max)
#
## lifted procs from `stats` module
#liftVectorFloatProc(variance)
#liftVectorFloatProc(standardDeviation)
#liftVectorFloatProc(skewness)
#liftVectorFloatProc(kurtosis)
#
## The following lifted procs are all lifted from the stdlib and the lifting to
## work on seqs is done in seqmath. Not all work atm, since some take additional args
## or return bools
## ---- from math.nim --------------
##liftScalarFloatProc(classify)
##liftScalarFloatProc(binom)
##liftScalarFloatProc(fac)
##liftScalarFloatProc(isPowerOfTwo)
##liftScalarFloatProc(nextPowerOfTwo)
##liftScalarFloatProc(countBits32)
##liftScalarFloatProc(random)
#liftScalarFloatProc(sqrt)
#liftScalarFloatProc(cbrt)
#liftScalarFloatProc(log10)
#liftScalarFloatProc(log2)
#liftScalarFloatProc(ln)
#liftScalarFloatProc(exp)
##liftScalarFloatProc2(fexp)
#liftScalarFloatProc(arccos)
#liftScalarFloatProc(arcsin)
#liftScalarFloatProc(arctan)
##liftScalarFloatProc2(arctan2)
#liftScalarFloatProc(cos)
#liftScalarFloatProc(cosh)
##liftScalarFloatProc2(hypot)
#liftScalarFloatProc(sin)
#liftScalarFloatProc(sinh)
#liftScalarFloatProc(tan)
#liftScalarFloatProc(tanh)
##liftScalarFloatProc2(pow)
#liftScalarFloatProc(erf)
#liftScalarFloatProc(erfc)
#liftScalarFloatProc(lgamma)
#liftScalarFloatProc(tgamma)
#liftScalarFloatProc(trunc)
#liftScalarFloatProc(floor)
#liftScalarFloatProc(ceil)
#liftScalarFloatProc(degToRad)
#liftScalarFloatProc(radToDeg)
##liftScalarFloatProc(gcd)
##liftScalarFloatProc(lcm)
#
#
#
#template liftVectorProcToPersVec(name: untyped, outType: untyped): untyped =
#  proc `name`*(v: PersistentVector[Value]): `outType` =
#    result = v[0 ..< v.len].mapIt(`name`(it.toFloat))
#
## liftVectorProcToPersVec(ln, seq[float])
#
##template liftProcToString(name: untyped, outType: untyped): untyped =
##  proc `name`(df: DataFrame, x: string): `outType` =
##    result = `name`(df[x])
##
##liftProcToString(mean, float)
#
#proc unique*(v: PersistentVector[Value]): seq[Value] =
#  ## returns a seq of all unique values in `v`
#  result = v.vToSeq.deduplicate
#
proc calcNewColumn*(df: DataFrame, fn: FormulaNode): (string, Column) =
  ## calculates a new column based on the `fn` given
  result = (fn.name, fn.fnV(df))
  #doAssert fn.lhs.kind == fkVariable, " was " & $fn
  #doAssert fn.lhs.val.kind == VString, " was " & $fn
  ## for column names we don't want explicit highlighting of string numbers, since
  ## we are dealing with strings anyways (`emphStrNumber = false`).
  #let colName = if fn.lhs.val.kind == VString:
  #                fn.lhs.val.str
  #              else:
  #                pretty(fn.lhs.val, emphStrNumber = false)
  ## mutable copy so that we can cache the result of `fn(arg)` if such a
  ## function call is involved
  #var mfn = fn
  #var newCol = newTensor[T](df.len)
  #for i in 0 ..< df.len:
  #  newCol[i] = mfn.rhs.evaluate(df, i)
  #result = (colName, toColumn(newCol))

proc selectInplace*[T: string | FormulaNode](df: var DataFrame, cols: varargs[T]) =
  ## Inplace variant of `select` below.
  var toDrop = toHashSet(df.getKeys)
  for fn in cols:
    when type(T) is string:
      toDrop.excl fn
    else:
      case fn.kind
      of fkNone: toDrop.excl fn.name
      of fkVariable:
        df[fn.name] = df[fn.val]
        toDrop.excl fn.name
      else: doAssert false, "function does not make sense for select"
  # now drop all required keys
  for key in toDrop: df.drop(key)

proc select*[T: string | FormulaNode](df: DataFrame, cols: varargs[T]): DataFrame =
  ## Returns the data frame cut to the names given as `cols`. The argument
  ## may either be the name of a column as a string, or a `FormulaNode` describing
  ## either a selection with a name applied in form of an "equation" (c/f mpg dataset):
  ## mySelection ~ hwy
  ## or just an `fkVariable` stating the name of the column. Using the former approach
  ## it's possible to select and rename a column at the same time.
  ## Note that the columns will be ordered from left to right given by the order
  ## of the `cols` argument!
  result = df
  result.selectInplace(cols)

proc mutateImpl(df: var DataFrame, fns: varargs[FormulaNode],
                dropCols: static bool) =
  ## implementation of mutation / transmutation. Allows to statically
  ## decide whether to only keep touched columns or not.
  var colsToKeep: seq[string]
  for fn in fns:
    if fn.kind in {fkNone,fkVariable}:
      colsToKeep.add fn.name
    elif fn.kind == fkVector:
      let (colName, newCol) = df.calcNewColumn(fn)
      df[colName] = newCol
      colsToKeep.add colName
  when dropCols:
    df.selectInplace(colsToKeep)

proc mutateInplace*(df: var DataFrame, fns: varargs[FormulaNode]) =
  ## Inplace variasnt of `mutate` below.
  df.mutateImpl(fns, dropCols = false)

proc mutate*(df: DataFrame, fns: varargs[FormulaNode]): DataFrame =
  ## Returns the data frame with an additional mutated column, described
  ## by the functions `fns`.
  ## Each formula `fn` given will be used to create a new column in the
  ## dataframe.
  ## We assume that the LHS of the formula corresponds to a fkVariable
  ## that's used to designate the new name.
  ## NOTE: If a given `fn` is a term (`fkTerm`) without an assignment
  ## (using `~`, kind `amDep`) or a function (`fkFunction`), the resulting
  ## column will be named after the stringification of the formula.
  ##
  ## E.g.: `df.mutate(f{"x" * 2})` will add the column `(* x 2)`.
  result = df
  result.mutateInplace(fns)

proc transmuteInplace*(df: var DataFrame, fns: varargs[FormulaNode]) =
  ## Inplace variant of `transmute` below.
  df.mutateImpl(fns, dropCols = true)

proc transmute*(df: DataFrame, fns: varargs[FormulaNode]): DataFrame =
  ## Returns the data frame cut to the columns created by `fns`, which
  ## should involve a calculation. To only cut to one or more columns
  ## use the `select` proc.
  ## A function may only contain a `fkVariable` in order to keep the
  ## column without modification.
  ## We assume that the LHS of the formula corresponds to a fkVariable
  ## that's used to designate the new name.
  ## NOTE: If a given `fn` is a term (`fkTerm`) without an assignment
  ## (using `~`, kind `amDep`) or a function (`fkFunction`), the resulting
  ## column will be named after the stringification of the formula.
  ##
  ## E.g.: `df.transmute(f{"x" * 2})` will create the column `(* x 2)`.
  # since result dataframe is empty, copy len of input
  result = df
  result.transmuteInplace(fns)

proc rename*(df: DataFrame, cols: varargs[FormulaNode]): DataFrame =
  ## Returns the data frame with the columns described by `cols` renamed to
  ## the names on the LHS of the given `FormulaNode`. All other columns will
  ## be left untouched.
  ## Note that the renamed columns will be stacked on the right side of the
  ## data frame!
  ## NOTE: The operator between the LHS and RHS of the formulas does not
  ## have to be `~`, but for clarity it should be.
  result = df
  for fn in cols:
    doAssert fn.kind == fkVariable
    result[fn.name] = df[fn.val.toStr]
    # remove the column of the old name
    result.drop(fn.val.toStr)

#proc getColsAsRows(df: DataFrame, keys: seq[string]): seq[Value] =
#  ## Given a dataframe `df` and column keys `keys`, returns a `seq[Value]`
#  ## where each `Value` is a `VObject` containing a single row, with
#  ## (key, value) pairs.
#  # now build the rows
#  result = newSeq[Value](df.len)
#  for i in 0 ..< result.len:
#    result[i] = newVObject()
#    for k in keys:
#      result[i][k] = df[k, i]
#
#import times
#proc getColsAsRowsIdx(df: DataFrame, keys: seq[string]): seq[(int, Value)] =
#  ## Given a dataframe `df` and column keys `keys`, returns a `seq[(int, Value)]`
#  ## where each `Value` is a `VObject` containing a single row, with
#  ## (key, value) pairs and `int` contains the index
#  # now build the rows
#  let t0 = cpuTime()
#  result = newSeq[(int, Value)](df.len)
#  var first = true
#  for k in keys:
#    withNativeDtype(df[k]):
#      let col = df[k].toTensor(dtype)
#      for i in 0 ..< result.len:
#        if first:
#          result[i][0] = i
#          result[i][1] = newVObject(keys.len)
#        result[i][1][k] = %~ (col[i])
#      first = false
#  let t1 = cpuTime()
#  echo "to rows took ", t1 - t0
#
proc arrangeSortImpl[T](toSort: var seq[(int, T)], order: SortOrder) =
  ## sorts the given `(index, Value)` pair according to the `Value`
  toSort.sort(
      cmp = (
        proc(x, y: (int, T)): int =
          result = system.cmp(x[1], y[1])
      ),
      order = order
    )

#proc sort*(a: var DataFrame, order = SortOrder.Ascending)

#template withNativeCols(cols: varargs[Column]): untyped =
#  for c in cols:
#

#proc sortBy(df: DataFrame, by: string, order: SortOrder): seq[int] =
#  withNativeDtype(df[by]):
#    var res = newSeq[(int, dtype)](df.len)
#    for i, val in toTensor(df[by], dtype):
#      res[i[0]] = (i[0], val)
#    res.arrangeSortImpl(order = order)
#    # after sorting here, check duplicate values of `val`, slice
#    # of those duplicates, use the next `by` in line and sort
#    # the remaining indices. Recursively do this until
#    result = res.mapIt(it[0])

proc sortBySubset(df: DataFrame, by: string, idx: seq[int], order: SortOrder): seq[int] =
  withNativeDtype(df[by]):
    var res = newSeq[(int, dtype)](idx.len)
    let t = toTensor(df[by], dtype)
    for i, val in idx:
      res[i] = (val, t[val])
    res.arrangeSortImpl(order = order)
    # after sorting here, check duplicate values of `val`, slice
    # of those duplicates, use the next `by` in line and sort
    # the remaining indices. Recursively do this until
    result = res.mapIt(it[0])

proc sortRecurse(df: DataFrame, by: seq[string],
                 startIdx: int,
                 resIdx: seq[int],
                 order: SortOrder): seq[int] =
  result = resIdx
  withNativeDtype(df[by[0]]):
    var res = newSeq[(int, dtype)](result.len)
    let t = toTensor(df[by[0]], dtype)
    for i, val in result:
      res[i] = (val, t[val])

    var mby = by
    mby.delete(0)
    var last = res[0][1]
    var cur = res[1][1]
    var i = startIdx
    var lastSearch = 0
    while i < df.len:
      cur = res[i][1]
      if last != cur or i == df.high:
        if i > lastSearch + 1:
          # sort between `lastSearch` and `i - 1`
          var subset = sortBySubset(df, mby[0], res[lastSearch ..< i].mapIt(it[0]), order = order)
          if mby.len > 1:
            # recurse again
            subset = sortRecurse(df, mby, lastSearch,
                                 resIdx = subset,
                                 order = order)

          result[lastSearch ..< i] = subset
        lastSearch = i
      last = res[i][1]
      inc i

proc sortBys(df: DataFrame, by: seq[string], order: SortOrder): seq[int] =
  withNativeDtype(df[by[0]]):
    var res = newSeq[(int, dtype)](df.len)
    for i, val in toTensor(df[by[0]], dtype):
      res[i[0]] = (i[0], val)
    res.arrangeSortImpl(order = order)
    # after sorting here, check duplicate values of `val`, slice
    # of those
    # duplicates, use the next `by` in line and sort
    # the remaining indices. Recursively do this until
    var resIdx = res.mapIt(it[0])
    if res.len > 1 and by.len > 1:
      resIdx = sortRecurse(df, by, startIdx = 1, resIdx = resIdx, order = order)
    result = resIdx

proc arrange*(df: DataFrame, by: seq[string], order = SortOrder.Ascending): DataFrame =
  ## sorts the data frame in ascending / descending `order` by key `by`
  # now sort by cols in ascending order of each col, i.e. ties will be broken
  # in ascending order of the columns
  var idxCol: seq[int]
  if by.len == 1:
    idxCol = sortBys(df, by, order = order)
  else:
    # in case of having multiple strings to sort by, first create a sequence of all
    # rows (only containig the columns to be sorted)
    ## old code:
    #var idxValCol = getColsAsRowsIdx(df, by)
    #idxValCol.arrangeSortImpl(order)
    #let test = idxValCol.mapIt(it[0])
    idxCol = sortBys(df, by, order = order)
    ## check it sorts correctly
    #doAssert test.len == idxCol.len
    #for idx in 0 ..< test.len:
    #  doAssert test[idx] == idxCol[idx], " was " & $test[idx] & " | " & $idxCol[idx] & " at " & $idx
    ## experimental (slow) via custom sort
    #var sortDf = df.select(by)
    #echo "start"
    #sortDf["idxSorted"] = toColumn arraymancer.arange(0, df.len)
    #sortDf.sort()
  result.len = df.len
  var data: Column
  for k in keys(df):
    withNativeDtype(df[k]):
      let col = df[k].toTensor(dtype)
      var res = newTensor[dtype](df.len)
      for i in 0 ..< df.len:
        #res[i] = col[idxValCol[i][0]]
        res[i] = col[idxCol[i]]
      data = toColumn res
    result[k] = data

proc arrange*(df: DataFrame, by: string, order = SortOrder.Ascending): DataFrame =
  result = df.arrange(@[by], order)

#proc `[]=`*[T](df: var DataFrame, key: string, idx: int, val: T) =
#  ## assign `val` to column `c` at index `idx`
#  ## If the types match, it just calls `[]=` on the tensor.
#  ## If they are compatible, `val` is converted to c's type.
#  ## If they are incompatible, `c` will be rewritten to an object
#  ## column.
#  var rewriteAsValue = false
#  case df[key].kind
#  of colFloat:
#    when T is float:
#      df[key].fCol[idx] = val
#    elif T is SomeNumber:
#      df[key].fCol[idx] = val.float
#  of colInt:
#    when T is int:
#      df[key].iCol[idx] = val
#    else:
#      rewriteAsValue = true
#  of colString:
#    when T is string:
#      df[key].sCol[idx] = val
#    else:
#      rewriteAsValue = true
#  of colBool:
#    when T is bool:
#      df[key].bCol[idx] = val
#    else:
#      rewriteAsValue = true
#  of colObject:
#    df[key].oCol[idx] = %~ val
#  if rewriteAsValue:
#    # rewrite as an object column
#    df = df[key].toObjectColumn()
#    df[key].oCol[idx] = %~ val

proc assign*(df: var DataFrame, key: string, idx1: int, c2: Column, idx2: int) =
  ## checks if the value in `c1` at `idx1` is equal to the
  ## value in `c2` at `idx2`
  withNativeDtype(df[key]):
    df[key, idx1] = c2[idx2, dtype]

proc innerJoin*(df1, df2: DataFrame, by: string): DataFrame =
  ## returns a data frame joined by the given key `by` in such a way as to only keep
  ## rows found in both data frames
  # build sets from both columns and seqs of their corresponding indices
  let
    df1S = df1.arrange(by)
    df2S = df2.arrange(by)
  withNativeDtype(df1S[by]):
    let
      col1 = df1S[by].toTensor(dtype).toRawSeq
      col2 = df2S[by].toTensor(dtype).toRawSeq
    let colSet1 = col1.toSet
    let colSet2 = col2.toSet
    let intersection = colSet1 * colSet2
    let idxDf1 = toSeq(0 ..< col1.len).filterIt(col1[it] in intersection)
    let idxDf2 = toSeq(0 ..< col2.len).filterIt(col2[it] in intersection)

    var
      i = 0
      j = 0
    let
      # for some reason we can't do toSeq(keys(df1S)) anymore...
      # This is due to https://github.com/nim-lang/Nim/issues/7322. `toSeq` isn't exported for now.
      keys1 = getKeys(df1S).toSet
      keys2 = getKeys(df2S).toSet
      allKeys = keys1 + keys2
    result = DataFrame()
    let resLen = (max(df1S.len, df2S.len))
    for k in allKeys:
      if k in df1S and k in df2S:
        doAssert df1S[k].kind == df2S[k].kind
        result[k] = initColumn(kind = df1S[k].kind, length = resLen)
      elif k in df1S and k notin df2S:
        result[k] = initColumn(kind = df1S[k].kind, length = resLen)
      if k notin df1S and k in df2S:
        result[k] = initColumn(kind = df2S[k].kind, length = resLen)
    var count = 0

    let df1By = df1S[by].toTensor(dtype)
    let df2By = df2S[by].toTensor(dtype)
    while i < idxDf1.len and
          j < idxDf2.len:
      let il = idxDf1[i]
      let jl = idxDf2[j]
      # indices point to same row, merge row
      if df1by[il] == df2by[jl]:
        for k in allKeys:
          if k in keys1 and k in keys2:
            doAssert equal(df1S[k], il, df2S[k], jl)
            result.assign(k, count, df1S[k], il)
          elif k in keys1:
            result.assign(k, count, df1S[k], il)
          elif k in keys2:
            result.assign(k, count, df2S[k], jl)
        inc count
      # now increase the indices as required
      if i != idxDf1.high and
         j != idxDf2.high and
         (df1by[idxDf1[i+1]] == df2by[idxDf2[j+1]]):
        inc i
        inc j
      elif i != idxDf1.high and (df1by[idxDf1[i+1]] == df2by[jl]):
        inc i
      elif j != idxDf2.high and (df1by[il] == df2by[idxDf2[j+1]]):
        inc j
      elif i == idxDf1.high and j == idxDf2.high:
        break
      else:
        raise newException(Exception, "This should not happen")
    result.len = count
    #for k in keys(seqTab):
    #  result[k] = seqTab[k].toPersistentVector

func toSet(t: Tensor[Value]): HashSet[Value] =
  for el in t:
    result.incl el

proc group_by*(df: DataFrame, by: varargs[string], add = false): DataFrame =
  ## returns a grouped data frame grouped by all keys `by`
  ## A grouped data frame is a lazy affair. It only calculates the groups,
  ## but unless e.g. `summarize` is called on it, remains unchanged.
  ## If `df` is already a grouped data frame and `add` is `true`, the
  ## groups given by `by` will be added as additional groups!
  doAssert by.len > 0, "Need at least one argument to group by!"
  if df.kind == dfGrouped and add:
    # just copy `df`
    result = df
  else:
    # copy over the data frame into new one of kind `dfGrouped` (cannot change
    # kind at runtime!)
    result = DataFrame(kind: dfGrouped)
    result.data = df.data
    result.len = df.len
  for key in by:
    result.groupMap[key] = toSet(result[key].toTensor(Value))

proc hashColumn(s: var seq[Hash], c: Column) =
  ## performs a partial hash of a DF. I.e. a single column, where
  ## the hash is added to each index in `s`. The hash is not finalized,
  ## rather the idea is to use this to hash all columns on `s` first.
  withNativeTensor(c, t):
    assert s.len == t.size
    for idx in 0 ..< t.size:
      s[idx] = s[idx] !& hash(t[idx])

func buildColHashes(df: DataFrame, keys: seq[string]): seq[Hash] =
  for i, k in keys:
    if i == 0:
      result = newSeq[Hash](df.len)
    result.hashColumn(df[k])
  # finalize the hashes
  result.applyIt(!$it)

iterator groups*(df: DataFrame, order = SortOrder.Ascending): (seq[(string, Value)], DataFrame) =
  ## yields the subgroups of a grouped DataFrame `df` and the `(key, Value)`
  ## pairs that were used to create the subgroup. If `df` has more than
  ## one grouping, a subgroup is defined by the pair of the groupings!
  ## E.g. mpg.group_by("class", "cyl")
  ## will yield all pairs of car ("class", "cyl")!
  ## Note: only non empty data frames will be yielded!
  doAssert df.kind == dfGrouped
  # sort by keys
  let keys = getKeys(df.groupMap)
  # arrange by all keys in ascending order
  let dfArranged = df.arrange(keys, order = order)
  # having the data frame in a sorted order, walk it and return each combination
  let hashes = buildColHashes(dfArranged, keys)

  #[
  Need new approach.
  Again calculate hashes of `keys` columns.
  Walk through DF.
  If hash == lastHash:
    accumulatte
  else:
    yield (seq(key, df[k][idx, Value]), slice of df)
  ]#
  proc buildClassLabel(df: DataFrame, keys: seq[string],
                       idx: int): seq[(string, Value)] =
    result = newSeq[(string, Value)](keys.len)
    for j, key in keys:
      result[j] = (key, df[key][idx, Value])

  var
    currentHash = hashes[0]
    lastHash = hashes[0]
    startIdx, stopIdx: int # indices which indicate from where to where a subgroup is located
  for i in 0 ..< dfArranged.len:
    currentHash = hashes[i]
    if currentHash == lastHash:
      # continue accumulating
      discard
    elif i > 0:
      # found the end of a subgroup or we're at the end of the DataFrame
      stopIdx = i - 1
      # return subgroup of startIdx .. stopIdx
      # build class label seq
      yield (buildClassLabel(dfArranged, keys, stopIdx), dfArranged[startIdx .. stopIdx])
      # set new start and stop idx
      startIdx = i
      lastHash = currentHash
    else:
      # should only happen for i == 0
      doAssert i == 0
      lastHash = currentHash
  # finally yield the last subgroup or the whole group, in case we only
  # have a single key
  yield (buildClassLabel(dfArranged, keys, dfArranged.high), dfArranged[startIdx .. dfArranged.high])

proc summarize*(df: DataFrame, fns: varargs[FormulaNode]): DataFrame =
  ## returns a data frame with the summaries applied given by `fn`. They
  ## are applied in the order in which they are given
  result = DataFrame(kind: dfNormal)
  var lhsName = ""
  case df.kind
  of dfNormal:
    for fn in fns:
      doAssert fn.kind == fkScalar
      lhsName = fn.name
      # just apply the function
      withNativeConversion(fn.valKind, get):
        let res = toColumn get(fn.fnS(df))
        result[lhsName] = res
        result.len = res.len
  of dfGrouped:
    # since `df.len >> fns.len = result.len` the overhead of storing the result
    # in a `Value` first does not matter in practice
    var sumStats = initTable[string, seq[Value]]()
    var keys = initTable[string, seq[Value]](df.groupMap.len)
    var idx = 0
    for fn in fns:
      doAssert fn.kind == fkScalar
      lhsName = fn.name
      sumStats[lhsName] = newSeqOfCap[Value](1000) # just start with decent size
      for class, subdf in groups(df):
        for (key, label) in class:
          if key notin keys: keys[key] = newSeqOfCap[Value](1000)
          keys[key].add label
        sumStats[lhsName].add fn.fnS(subDf)
    for k, vals in keys:
      result[k] = toNativeColumn vals
    for k, vals in sumStats:
      result[k] = toNativeColumn vals
      result.len = vals.len

proc count*(df: DataFrame, col: string, name = "n"): DataFrame =
  ## counts the number of elements per type in `col` of the data frame.
  ## Basically a shorthand for df.group_by.summarize(f{length(col)}).
  ## TODO: handle already grouped dataframes.
  result = DataFrame()
  let grouped = df.group_by(col, add = true)
  var counts = newSeqOfCap[int](1000) # just start with decent size
  var keys = initTable[string, seq[Value]](grouped.groupMap.len)
  var idx = 0
  for class, subdf in groups(grouped):
    for (c, val) in class:
      if c notin keys: keys[c] = newSeqOfCap[Value](1000)
      keys[c].add val
    counts.add subDf.len
    inc idx
  for k, vals in keys:
    result[k] = toNativeColumn vals
  result[name] = toColumn counts
  result.len = idx

proc bind_rows*(dfs: varargs[(string, DataFrame)], id: string = ""): DataFrame =
  ## `bind_rows` combines several data frames row wise (i.e. data frames are
  ## stacked on top of one another).
  ## If a given column does not exist in one of the data frames, the corresponding
  ## rows of the data frame missing it, will be filled with `VNull`.
  result = DataFrame(len: 0)
  var totLen = 0
  for (idVal, df) in dfs:
    totLen += df.len
    # first add `id` column
    if id.len > 0 and id notin result:
      result[id] = toColumn( newTensorWith(df.len, idVal) )
    elif id.len > 0:
      result[id] = result[id].add toColumn( newTensorWith(df.len, idVal) )
    var lastSize = 0
    for k in keys(df):
      if k notin result:
        # create this new column consisting of `VNull` up to current size
        if result.len > 0:
          result[k] = nullColumn(result.len)
        else:
          result[k] = initColumn(df[k].kind)
      # now add the current vector
      if k != id:
        # TODO: write a test for multiple bind_rows calls in a row!
        result[k] = result[k].add df[k]
      lastSize = max(result[k].len, lastSize)
    result.len = lastSize

  # possibly extend vectors, which have not been filled with `VNull` (e.g. in case
  # the first `df` has a column `k` with `N` entries, but another `M` entries are added to
  # the `df`. Since `k` is not found in another `df`, it won't be extend in the loop above
  for k in keys(result):
    if result[k].len < result.len:
      # extend this by `VNull`
      result[k] = result[k].add nullColumn(result.len - result[k].len)
  doAssert totLen == result.len, " totLen was: " & $totLen & " and result.len " & $result.len

template bind_rows*(dfs: varargs[DataFrame], id: string = ""): DataFrame =
  ## Overload of `bind_rows` above, for automatic creation of the `id` values.
  ## Using this proc, the different data frames will just be numbered by their
  ## order in the `dfs` argument and the `id` column is filled with those values.
  ## The values will always appear as strings, even though we use integer
  ## numbering.
  ## `bind_rows` combines several data frames row wise (i.e. data frames are
  ## stacked on top of one another).
  ## If a given column does not exist in one of the data frames, the corresponding
  ## rows of the data frame missing it, will be filled with `VNull`.
  var ids = newSeq[string]()
  for i, df in dfs:
    ids.add $i
  let args = zip(ids, dfs)
  bind_rows(args, id)

proc add*(df: var DataFrame, dfToAdd: DataFrame) =
  ## The simplest form of "adding" a data frame. If the keys match exactly or
  ## `df` is empty `dfToAdd` will be stacked below. This makes a key check and then
  ## calls `bind_rows` for the job.
  if df.len == 0:
    df = dfToAdd
  else:
    doAssert df.getKeys == dfToAdd.getKeys, "all keys must match to add dataframe!"
    df = bind_rows([("", df), ("", dfToAdd)])

proc setDiff*(df1, df2: DataFrame, symmetric = false): DataFrame =
  ## returns a `DataFrame` with all elements in `df1` that are not found in
  ## `df2`. If `symmetric` is true, the symmetric difference of the dataset is
  ## returned, i.e. elements which are either not in `df1` ``or`` not in `df2`.
  ## NOTE: Currently simple implementation based on `HashSet`. Iterates
  ## both dataframes once to generate sets, calcualtes intersection and returns
  ## difference as new `DataFrame`
  ## Considers whole rows for comparison. The result is potentially unsorted!
  #[
  Calculate custom hash for each row in each table.
  Keep var h1, h2 = seq[Hashes] where seq[Hashes] is hash of of row.
  Calculate hashes by column! Get df1 column 1, start hash, column 2, add to hash etc.
  Same for df2.
  Compare hashes either symmetric, or asymmetric.
  Use indices of allowed hashes to rebuild final DF via columns again. Should be fast
  ]#
  if getKeys(df1) != getKeys(df2):
    # if not all keys same, all rows different by definition!
    return df1

  let keys = getKeys(df1)
  let h1 = buildColHashes(df1, keys)
  let h2 = buildColHashes(df2, keys)
  # given hashes apply set difference
  var diff: HashSet[Hash]
  if symmetric:
    diff = symmetricDifference(toSet(h1), toSet(h2))
    var idxToKeep1 = newSeqOfCap[int](diff.card)
    var idxToKeep2 = newSeqOfCap[int](diff.card)
    for idx, h in h1:
      if h in diff:
        # keep this row
        idxToKeep1.add idx
    for idx, h in h2:
      if h in diff:
        # keep this row
        idxToKeep2.add idx
    # rebuild those from df1, then those from idx2
    for k in keys:
      result[k] = df1[k].filter(toTensor(idxToKeep1))
      # fill each key with the non zero elements
    result.len = idxToKeep1.len
    var df2Res: DataFrame
    for k in keys:
      df2Res[k] = df2[k].filter(toTensor(idxToKeep2))
      # fill each key with the non zero elements
    df2Res.len = idxToKeep2.len
    # stack the two data frames
    result.add df2Res
  else:
    diff = toSet(h1) - toSet(h2)
    # easy
    var idxToKeep = newTensor[int](diff.card)
    var i = 0
    for idx, h in h1:
      if h in diff:
        # keep this row
        idxToKeep[i] = idx
        inc i
    # rebuild the idxToKeep columns
    for k in keys:
      result[k] = df1[k].filter(idxToKeep)
      # fill each key with the non zero elements
    result.len = idxToKeep.size

proc head*(df: DataFrame, num: int): DataFrame =
  ## returns the head of the DataFrame. `num` elements
  result = df[0 ..< num]

proc tail*(df: DataFrame, num: int): DataFrame =
  ## returns the tail of the DataFrame. `num` elements
  result = df[^num .. df.high]

proc gather*(df: DataFrame, cols: varargs[string],
             key = "key", value = "value", dropNulls = false): DataFrame =
  ## gathers the `cols` from `df` and merges these columns into two new columns
  ## where the `key` column contains the name of the column from which the `value`
  ## entry is taken. I.e. transforms `cols` from wide to long format.
  let remainCols = getKeys(df).toSet.difference(cols.toSet)
  let newLen = cols.len * df.len
  # assert all columns same type
  # TODO: relax this restriction, auto convert to `colObject` if non matching
  assert cols.mapIt(df[it].kind).deduplicate.len == 1, "all gathered columns must be of the same type!"
  var keyTensor = newTensorUninit[string](newLen)
  withNativeDtype(df[cols[0]]):
    var valTensor = newTensorUninit[dtype](newLen)
    for i in 0 ..< cols.len:
      # for each column, clone the `col` tensor once to the correct position
      let col = cols[i]
      keyTensor[i * df.len ..< (i + 1) * df.len] = col #.clone()
      # TODO: make sure we don't have to clone the given tensor!
      valTensor[i * df.len ..< (i + 1) * df.len] = df[col].toTensor(dtype)
    # now create result
    result[key] = toColumn keyTensor
    result[value] = toColumn valTensor
  # For remainder of columns, just use something like `repeat`!, `stack`, `concat`
  for rem in remainCols:
    withNativeDtype(df[rem]):
      let col = df[rem].toTensor(dtype)
      var fullCol = newTensorUninit[dtype](newLen)
      for i in 0 ..< cols.len:
        # for each column, clone the `col` tensor once to the correct position
        fullCol[i * df.len ..< (i + 1) * df.len] = col #.clone()
      result[rem] = toColumn(fullCol)
  result.len = newLen

proc unique*(df: DataFrame, cols: varargs[string]): DataFrame =
  ## returns a DF with only distinct rows. If one or more `cols` are given
  ## the uniqueness of a row is only determined based on those columns. By
  ## default all columns are considered.
  ## NOTE: The corresponding `dplyr` function is `distinct`. The choice for
  ## `unique` was made, since `distinct` is a keyword in Nim!
  var mcols = @cols
  if mcols.len == 0:
    mcols = getKeys(df)
  let hashes = buildColHashes(df, mcols)
  var hSet = toSet(hashes)
  # walk df, build indices from `hashes` which differ
  var idxToKeep = newTensor[int](hSet.card)
  var idx = 0
  for i in 0 ..< df.len:
    if hashes[i] in hSet:
      idxToKeep[idx] = i
      # remove from set to not get duplicates!
      hSet.excl hashes[i]
      inc idx
  # apply idxToKeep as filter
  for k in mcols:
    result[k] = df[k].filter(idxToKeep)
    # fill each key with the non zero elements
  result.len = idxToKeep.size

#proc evaluate*[T](node: FormulaNode[T], data: DataFrame, idx: int): T =
#  case node.kind
#  of fkVariable:
#    case node.val.kind
#    of VString:
#      # the given node corresponds to a key of the data frame
#      if node.val.str in data:
#        result = data[node.val.str][idx]
#      else:
#        # if it's not a key, we use the literal
#        result = node.val
#    of VFloat, VInt, VBool:
#      # take the literal value of the node
#      result = node.val
#    else:
#      raise newException(Exception, "Node kind of " & $node.kind & " does not " &
#        "make sense for evaluation!")
#  of fkTerm:
#    case node.op
#    of amPlus:
#      result = node.lhs.evaluate(data, idx) + node.rhs.evaluate(data, idx)
#    of amMinus:
#      result = node.lhs.evaluate(data, idx) - node.rhs.evaluate(data, idx)
#    of amMul:
#      result = node.lhs.evaluate(data, idx) * node.rhs.evaluate(data, idx)
#    of amDiv:
#      result = node.lhs.evaluate(data, idx) / node.rhs.evaluate(data, idx)
#    # For booleans we have to wrap the result again in a `Value`, since boolean
#    # operators of `Value` will still return a `bool`
#    of amGreater:
#      result = %~ (node.lhs.evaluate(data, idx) > node.rhs.evaluate(data, idx))
#    of amLess:
#      result = %~ (node.lhs.evaluate(data, idx) < node.rhs.evaluate(data, idx))
#    of amGeq:
#      result = %~ (node.lhs.evaluate(data, idx) >= node.rhs.evaluate(data, idx))
#    of amLeq:
#      result = %~ (node.lhs.evaluate(data, idx) <= node.rhs.evaluate(data, idx))
#    of amAnd:
#      result = %~ (node.lhs.evaluate(data, idx).toBool and node.rhs.evaluate(data, idx).toBool)
#    of amOr:
#      result = %~ (node.lhs.evaluate(data, idx).toBool or node.rhs.evaluate(data, idx).toBool)
#    of amXor:
#      result = %~ (node.lhs.evaluate(data, idx).toBool xor node.rhs.evaluate(data, idx).toBool)
#    of amEqual:
#      result = %~ (node.lhs.evaluate(data, idx) == node.rhs.evaluate(data, idx))
#    of amUnequal:
#      result = %~ (node.lhs.evaluate(data, idx) != node.rhs.evaluate(data, idx))
#    of amDep:
#      raise newException(Exception, "Cannot evaluate a term still containing a dependency!")
#  of fkFunction:
#    # for now assert that the argument to the function is just a string
#    # Extend this if support for statements like `mean("x" + "y")` (whatever
#    # that is even supposed to mean) is to be added.
#    doAssert node.arg.kind == fkVariable
#    # we also convert to float for the time being. Implement a different proc or make this
#    # generic, we want to support functions returning e.g. `string` (maybe to change the
#    # field name at runtime via some magic proc)
#    case node.fnKind
#    of funcVector:
#      # a function taking a vector. Check if result already computed, else apply
#      # to the column and store the result
#      doAssert node.arg.val.kind == VString
#      if node.res.isSome:
#        result = node.res.unsafeGet
#      else:
#        result = node.fnV(data[node.arg.val.str])
#        node.res = some(result)
#    of funcScalar:
#      # just a function taking a scalar. Apply to current `idx`
#      result = node.fnS(data[node.arg.val.str][idx])

#proc reduce*(node: FormulaNode, data: DataFrame): Value =
#  ## Reduces the data frame under a given `FormulaNode`.
#  ## It returns a single value from a whole data frame (by working on
#  ## a single column)
#  case node.kind
#  of fkVariable:
#    result = node.val
#  of fkFunction:
#    # for now assert that the argument to the function is just a string
#    # Extend this if support for statements like `mean("x" + "y")` (whatever
#    # that is even supposed to mean) is to be added.
#    doAssert node.arg.kind == fkVariable
#    # we also convert to float for the time being. Implement a different proc or make this
#    # generic, we want to support functions returning e.g. `string` (maybe to change the
#    # field name at runtime via some magic proc)
#    case node.fnKind
#    of funcVector:
#      # here we do ``not`` store the result of the calculation in the `node`, since
#      # we may run the same function on different datasets + we only call this
#      # "once" anyways
#      doAssert node.arg.val.kind == VString
#      result = node.fnV(data[node.arg.val.str])
#    of funcScalar:
#      raise newException(Exception, "The given evaluator function must work on" &
#        " a whole column!")
#  of fkTerm:
#    let lhs = reduce(node.lhs, data)
#    let rhs = reduce(node.rhs, data)
#    result = evaluate FormulaNode(kind: fkTerm, op: node.op, lhs: f{lhs}, rhs: f{rhs})
#
#proc evaluate*(node: FormulaNode, data: DataFrame): PersistentVector[Value] =
#  ## evaluation of a data frame under a given `FormulaNode`. This is a non-reducing
#  ## operation. It returns a `PersitentVector[Value]` from a whole data frame (by working on
#  ## a single column) and applying `node` to each element.
#  case node.kind
#  of fkVariable:
#    case node.val.kind
#    of VString:
#      # the given node corresponds to a key of the data frame
#      # TODO: maybe extend this so that if `node.val` is ``not`` a key of the dataframe
#      # we take the literal string value instead?
#      if node.val.str in data:
#        result = data[node.val.str]
#      else:
#        # if it's not a key, we use the literal
#        result = toPersistentVector(toSeq(0 ..< data.len).mapIt(node.val))
#    of VFloat, VInt, VBool:
#      # take the literal value of the node
#      result = toPersistentVector(toSeq(0 ..< data.len).mapIt(node.val))
#    else:
#      raise newException(Exception, "Node kind of " & $node.kind & " does not " &
#        "make sense for evaluation!")
#  of fkTerm:
#    let lhs = evaluate(node.lhs, data)
#    let rhs = evaluate(node.rhs, data)
#    doAssert lhs.len == rhs.len
#    var res = newSeq[Value](lhs.len)
#    for i in 0 ..< lhs.len:
#      res[i] = evaluate FormulaNode(kind: fkTerm, op: node.op, lhs: f{lhs[i]}, rhs: f{rhs[i]})
#    result = toPersistentVector(res)
#  of fkFunction:
#    case node.fnKind
#    of funcScalar:
#      # just a function taking a scalar. Apply to current `idx`
#      var res = newSeq[Value](data.len)
#      for i in 0 ..< data.len:
#        res[i] = node.evaluate(data, i)
#      result = toPersistentVector(res)
#    of funcVector:
#      raise newException(Exception, "Reductive vector like proc cannot be evaluated to " &
#        "return a vector!")
