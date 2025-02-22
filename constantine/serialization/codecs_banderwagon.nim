# Constantine
# Copyright (c) 2018-2019    Status Research & Development GmbH
# Copyright (c) 2020-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## ############################################################
##
##                 Banderwagon Serialization
##
## ############################################################

import
  ../platforms/abstractions,
  ../math/config/curves,
  ../math/elliptic/[
    ec_twistededwards_affine,
    ec_twistededwards_projective,
    ec_twistededwards_batch_ops
  ],
  ../math/arithmetic/limbs_montgomery,
  ../math/[
    arithmetic/bigints,
    extension_fields,
    arithmetic,
    constants/banderwagon_subgroups
  ],
  ../math/io/[io_bigints, io_fields],
  ./codecs_status_codes

type
  EC_Prj* = ECP_TwEdwards_Prj[Fp[Banderwagon]]
  EC_Aff* = ECP_TwEdwards_Aff[Fp[Banderwagon]]

# Input validation
# ------------------------------------------------------------------------------------------------
func validate_scalar*(scalar: matchingOrderBigInt(Banderwagon)): CttCodecScalarStatus =
  ## Validate a scalar
  ## Regarding timing attacks, this will leak information
  ## if the scalar is 0 or larger than the curve order.
  if scalar.isZero().bool():
    return cttCodecScalar_Zero
  if bool(scalar >= Banderwagon.getCurveOrder()):
    return cttCodecScalar_ScalarLargerThanCurveOrder
  return cttCodecScalar_Success

func make_scalar_mod_order*(reduced_scalar: var Fr[Banderwagon], src: array[32, byte], order: static Endianness = bigEndian): bool =
  ## Convert a 32-byte array to a field element, reducing it modulo Banderwagon's curve order if necessary.

  # Which can be safely stored in a 256 BigInt
  # Now incase of the scalar overflowing the last 3-bits
  # it is converted from its natural representation
  # to the Montgomery residue form
  var res: bool = false
  var scalar {.noInit.}: BigInt[256]
  scalar.unmarshal(src, order)

  getMont(reduced_scalar.mres.limbs, scalar.limbs,
        Fr[Banderwagon].fieldMod().limbs,
        Fr[Banderwagon].getR2modP().limbs,
        Fr[Banderwagon].getNegInvModWord(),
        Fr[Banderwagon].getSpareBits())
  res = true
  return res

    

func serialize*(dst: var array[32, byte], P: EC_Prj): CttCodecEccStatus =
  ## Serialize a Banderwagon point(x, y) in the format
  ## 
  ## serialize = bigEndian( sign(y) * x )
  ## If y is not lexicographically largest
  ## set x -> -x
  ## then serialize
  ## 
  ## Returns cttCodecEcc_Success if successful
  ## Spec: https://hackmd.io/@6iQDuIePQjyYBqDChYw_jg/BJBNcv9fq#Serialisation

  # Setting all bits to 0 for the point of infinity
  if P.isInf().bool():
    for i in 0 ..< dst.len:
      dst[i] = byte 0
    return cttCodecEcc_Success
  
  # Convert the projective points into affine format before encoding
  var aff {.noInit.}: EC_Aff
  aff.affine(P)

  let lexicographicallyLargest = aff.y.toBig() >= Fp[Banderwagon].getPrimeMinus1div2()

  if not lexicographicallyLargest.bool():
    aff.x.neg()

  dst.marshal(aff.x, bigEndian)
  return cttCodecEcc_Success

func deserialize_unchecked*(dst: var EC_Prj, src: array[32, byte]): CttCodecEccStatus =
  ## Deserialize a Banderwagon point (x, y) in format
  ## 
  ## if y is not lexicographically largest
  ## set y -> -y
  ## 
  ## Returns cttCodecEcc_Success if successful
  ## https://hackmd.io/@6iQDuIePQjyYBqDChYw_jg/BJBNcv9fq#Serialisation
  # If infinity, src must be all zeros
  var check: bool = true
  for i in 0 ..< src.len:
    if src[i] != byte 0:
      check = false
      break
  if check:
    dst.setInf()
    return cttCodecEcc_PointAtInfinity
  
  var t{.noInit.}: matchingBigInt(Banderwagon)
  t.unmarshal(src, bigEndian)

  if bool(t >= Banderwagon.Mod()):
    return cttCodecEcc_CoordinateGreaterThanOrEqualModulus

  var x{.noInit.}: Fp[Banderwagon]
  x.fromBig(t)

  let onCurve = dst.trySetFromCoordX(x)
  if not(bool onCurve):
    return cttCodecEcc_PointNotOnCurve

  let isLexicographicallyLargest = dst.y.toBig() >= Fp[Banderwagon].getPrimeMinus1div2()
  dst.y.cneg(not isLexicographicallyLargest)

  return cttCodecEcc_Success

func deserialize*(dst: var EC_Prj, src: array[32, byte]): CttCodecEccStatus =
  ## Deserialize a Banderwagon point (x, y) in format
  ## 
  ## Also checks if the point lies in the banderwagon scheme subgroup
  ## 
  ## Returns cttCodecEcc_Success if successful
  ## Returns cttCodecEcc_PointNotInSubgroup if doesn't lie in subgroup
  result = deserialize_unchecked(dst, src)
  if result != cttCodecEcc_Success:
    return result

  if not(bool dst.isInSubgroup()):
    return cttCodecEcc_PointNotInSubgroup

  return cttCodecEcc_Success

## ############################################################
##
##              Banderwagon Scalar Serialization
##
## ############################################################
## 
func serialize_scalar*(dst: var array[32, byte], scalar: matchingOrderBigInt(Banderwagon), order: static Endianness = bigEndian): CttCodecScalarStatus =
  ## Adding an optional Endianness param default at BigEndian
  ## Serialize a scalar
  ## Returns cttCodecScalar_Success if successful
  dst.marshal(scalar, order)
  return cttCodecScalar_Success

## ############################################################
##
##              Banderwagon Scalar Deserialization
##
## ############################################################
## 
func deserialize_scalar*(dst: var matchingOrderBigInt(Banderwagon), src: array[32, byte], order: static Endianness = bigEndian): CttCodecScalarStatus =
  ## Adding an optional Endianness param default at BigEndian
  ## Deserialize a scalar
  ## Also validates the scalar range
  ##
  ## This is protected against side-channel unless the scalar is invalid.
  ## In that case it will leak whether it's all zeros or larger than the curve order.
  ##
  ## This special-cases (and leaks) 0 scalar as this is a special-case in most protocols
  ## or completely invalid (for secret keys).
  dst.unmarshal(src, order)
  let status = validate_scalar(dst)
  if status != cttCodecScalar_Success:
    dst.setZero()
    return status
  return cttCodecScalar_Success

func deserialize_scalar_mod_order* (dst: var Fr[Banderwagon], src: array[32, byte], order: static Endianness = bigEndian): CttCodecScalarStatus =
  ## Deserialize a scalar
  ## Take mod value of the scalar (MOD CurveOrder)
  ## If the scalar values goes out of range
  let stat {.used.} = dst.make_scalar_mod_order(src, order)
  debug: doAssert stat, "transcript_gen.deserialize_scalar_mod_order: Unexpected failure"

  return cttCodecScalar_Success
  
## ############################################################
##
##              Banderwagon Batch Serialization
##
## ############################################################

func serializeBatch*(
    dst: ptr UncheckedArray[array[32, byte]],
    points: ptr UncheckedArray[EC_Prj],
    N: int,
  ) : CttCodecEccStatus {.noInline.} =

  # collect all the z coordinates
  var zs = allocStackArray(Fp[Banderwagon], N)
  var zs_inv = allocStackArray(Fp[Banderwagon], N)
  for i in 0 ..< N:
    zs[i] = points[i].z

  zs_inv.batchInvert(zs, N)
  
  for i in 0 ..< N:
    var X: Fp[Banderwagon]
    var Y: Fp[Banderwagon]

    X.prod(points[i].x, zs_inv[i])
    Y.prod(points[i].y, zs_inv[i])

    let lexicographicallyLargest = Y.toBig() >= Fp[Banderwagon].getPrimeMinus1div2()
    if not lexicographicallyLargest.bool():
      X.neg()

    dst[i].marshal(X, bigEndian)

  return cttCodecEcc_Success

func serializeBatch*[N: static int](
        dst: var array[N, array[32, byte]],
        points: array[N, EC_Prj]): CttCodecEccStatus {.inline.} =
  return serializeBatch(dst.asUnchecked(), points.asUnchecked(), N)
