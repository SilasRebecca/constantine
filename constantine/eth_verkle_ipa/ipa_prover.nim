# Constantine
# Copyright (c) 2018-2019    Status Research & Development GmbH
# Copyright (c) 2020-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# ############################################################
#
# All the util functions for Inner Product Arguments Prover
#
# ############################################################

import
  ./[transcript_gen, common_utils, eth_verkle_constants, barycentric_form],
  ../platforms/primitives,
  ../hashes,
  ../serialization/[
    codecs_banderwagon,
    codecs_status_codes,
  ],
  ../math/config/[type_ff, curves],
  ../math/elliptic/[ec_twistededwards_projective],
  ../math/arithmetic,
  ../math/elliptic/ec_scalar_mul, 
  ../platforms/[views],
  ../curves_primitives

# ############################################################
#
# Inner Product Argument using Pedersen Commitments
#
# ############################################################

# This Pedersen Commitment function shall be used in specifically the Split scalars 
# and Split points that are used in the IPA polynomial

# Further reference refer to this https://dankradfeist.de/ethereum/2021/07/27/inner-product-arguments.html

func genIPAConfig*(res: var IPASettings, ipaTranscript: var IpaTranscript[CryptoHash, 32]) : bool {.inline.} =
  # Initiates a new IPASettings
  # IPASettings has all the necessary information related to create an IPA proof
  # such as SRS, precomputed weights for Barycentric formula

  # The number of rounds for the prover and verifier must be in the IPA argument,
  # it should be log2 of the size of the input vectors for the IPA, since the vector size is halved on each round.

  # genIPAConfig( ) generates the SRS, Q and the precomputed weights for barycentric formula. The SRS is generated
  # as random points of the VerkleDomain where the relative discrete log is unknown between each generator.
  res.SRS.generate_random_points(ipaTranscript, uint64(VerkleDomain))
  res.Q_val.fromAffine(Banderwagon.getGenerator())
  res.precompWeights.newPrecomputedWeights()
  res.numRounds.computeNumRounds(uint64(VerkleDomain))
  return true

func createIPAProof*[IPAProof] (res: var IPAProof, transcript: var CryptoHash, ic: IPASettings, commitment: EC_P, a: var openArray[Fr[Banderwagon]], evalPoint: Fr[Banderwagon]) : bool {.inline.} =
  ## createIPAProof creates an IPA proof for a committed polynomial in evaluation form.
  ## `a` vectors are the evaluation points in the domain, and `evalPoint` represents the evaluation point.
  transcript.domain_separator(asBytes"ipa")
  var b {.noInit.}: array[VerkleDomain, Fr[Banderwagon]]
  
  b.computeBarycentricCoefficients(ic.precompWeights, evalPoint)
  var innerProd {.noInit.}: Fr[Banderwagon]

  innerProd.computeInnerProducts(a, b)

  transcript.pointAppend(asBytes"C", commitment)
  transcript.scalarAppend(asBytes"input point", evalPoint.toBig())
  transcript.scalarAppend(asBytes"output point", innerProd.toBig())

  var w : matchingOrderBigInt(Banderwagon)
  w.generateChallengeScalar(transcript, asBytes"w")

  var q {.noInit.} : EC_P
  q = ic.Q_val
  q.scalarMul(w)

  var current_basis {.noInit.}: array[VerkleDomain, EC_P]
  current_basis = ic.SRS

  var num_rounds = ic.numRounds

  var L {.noInit.}: array[8, EC_P]

  var R {.noInit.}: array[8, EC_P]

  var a_view = a.toView()
  var b_view = b.toView()
  var current_basis_view = current_basis.toView()

  for i in 0 ..< int(num_rounds):
    var a_L = a_view.chunk(0, a_view.len shr 1)
    var a_R = a_view.chunk(a_view.len shr 1 + 1, a_view.len)

    var b_L = b_view.chunk(0, b_view.len shr 1)
    var b_R = b_view.chunk(b_view.len shr 1 + 1, b_view.len)

    var G_L = current_basis_view.chunk(0, current_basis_view.len shr 1)
    var G_R = current_basis_view.chunk(current_basis_view.len shr 1 + 1, current_basis_view.len)

    var z_L {.noInit.}: Fr[Banderwagon]
    z_L.computeInnerProducts(a_R, b_L)

    var z_R {.noInit.}: Fr[Banderwagon]
    z_R.computeInnerProducts(a_L, b_R)
    var one : Fr[Banderwagon]
    one.setOne()

    var C_L_1 {.noInit.}: EC_P
    C_L_1.pedersen_commit_varbasis(G_L.toOpenArray(), G_L.toOpenArray().len, a_R.toOpenArray(), a_R.len)

    var fp1 : array[2, EC_P]
    fp1[0] = C_L_1
    fp1[1] = q

    var fr1 : array[2, Fr[Banderwagon]]
    fr1[0] = one
    fr1[1] = z_L

    var C_L {.noInit.}: EC_P
    C_L.pedersen_commit_varbasis(fp1, fp1.len, fr1, fr1.len)

    var C_R_1 {.noInit.}: EC_P
    C_R_1.pedersen_commit_varbasis(G_R.toOpenArray(), G_R.toOpenArray().len, a_L.toOpenArray(), a_L.len)

    var C_R {.noInit.}: EC_P

    var fp2 : array[2, EC_P]
    fp2[0] = C_R_1
    fp2[1] = q

    var fr2: array[2, Fr[Banderwagon]]
    fr2[0] = one
    fr2[1] = z_R

    C_R.pedersen_commit_varbasis(fp2, fp2.len, fr2, fr2.len)

    L[i] = C_L
    R[i] = C_R

    transcript.pointAppend(asBytes"L", C_L)
    transcript.pointAppend(asBytes"R", C_R)

    var x_big: matchingOrderBigInt(Banderwagon)
    x_big.generateChallengeScalar(transcript, asBytes"x")

    var x: Fr[Banderwagon]
    x.fromBig(x_big)

    var xInv: Fr[Banderwagon]
    xInv.inv(x)

    a.foldScalars(a_L.toOpenArray(), a_R.toOpenArray(), x)

    b.foldScalars(b_L.toOpenArray(), b_R.toOpenArray(), xInv)

    current_basis.foldPoints(G_L.toOpenArray(), G_R.toOpenArray(), xInv)

  debug: doAssert not(a.len == 1), "Length of `a` should be 1 at the end of the reduction"

  res.L_vector = L
  res.R_vector = R
  res.A_scalar = a[0]
  return true

# ############################################################
#
# IPA proof seriaizer
#
# ############################################################

func serializeVerkleIPAProof* (dst: var VerkleIPAProofSerialized, src: IPAProof): bool =
  ## IPA Proofs in Verkle consists of a Left array of 8 Base Field points, a Right array of 8 Base Field points, and a Scalar Field element
  ## During serialization the format goes as follows:
  ## 
  ## L[0] (32 - byte array) L[1] (32 - byte array) .... L[7] (32 - byte array) ..... R[0] (32 - byte array) ... R[7] (32 - byte array) A (32 - byte array)
  ## 
  ## Which means the size of the byte array should be :
  ## 
  ## 32 * 8 (for Left half) + 32 * 8 (for Right half) + 32 * 1 (for Scalar) = 32 * 17 = 544 elements in the byte array.
  ## 
  ## ----------------------------------------------------------
  ## 
  ## Note that checks like Subgroup check for Banderwagon Points for Base Field elements in L and R, 
  ## And checks for a valid scalar checking the Banderwagon scalar Curve Order is MANDATORY. They are all checked in the further low level functions
  ## 
  var res = false
  var L_bytes {.noInit.} : array[8, array[32, byte]]
  var R_bytes {.noInit.} : array[8, array[32, byte]]

  let stat1 = L_bytes.serializeBatch(src.L_vector)
  doAssert stat1 == cttCodecEcc_Success, "Batch serialization Failure!"


  let stat2 = R_bytes.serializeBatch(src.R_vector)
  doAssert stat2 == cttCodecEcc_Success, "Batch Serialization Failure!"

  var A_bytes {.noInit.} : array[32, byte]
  let stat3 = A_bytes.serialize_scalar(src.A_scalar.toBig(), littleEndian)
  doAssert stat3 == cttCodecScalar_Success, "Scalar Serialization Failure!"

  var idx : int = 0

  for i in 0 ..< 8:
    for j in 0 ..< 32:
      dst[idx] = L_bytes[i][j]
      idx = idx + 1

  discard L_bytes

  for i in 0 ..< 8:
    for j in 0 ..< 32:
      dst[idx] = R_bytes[i][j]
      idx = idx + 1

  discard R_bytes

  for i in 0 ..< 32:
    dst[idx] = A_bytes[i]
    idx = idx + 1

  discard A_bytes
  
  res = true
  return res

# ############################################################
#
# IPA proof deserializer
#
# ############################################################

func deserializeVerkleIPAProof* (dst: var IPAProof, src: var VerkleIPAProofSerialized ): bool = 
  ## IPA Proofs in Verkle consists of a Left array of 8 Base Field points, a Right array of 8 Base Field points, and a Scalar Field element
  ## During deserialization the format goes as follows:
  ## 
  ## L[0] (32 - byte array) L[1] (32 - byte array) .... L[7] (32 - byte array) ..... R[0] (32 - byte array) ... R[7] (32 - byte array) A (32 - byte array)
  ## 
  ## Which means the size of the byte array should be :
  ## 
  ## 32 * 8 (for Left half) + 32 * 8 (for Right half) + 32 * 1 (for Scalar) = 32 * 17 = 544 elements in the byte array.
  ## ----------------------------------------------------------
  ## 
  ## Note that check for Lexicographically Largest criteria for the Y - coordinate of the Twisted Edward Banderwagon point is MANDATORY
  ## And, is pre-checked within this function from the `deserialize` function.
  ## 
  var res = false
  
  var L_bytes {.noInit.} : array[8, array[32, byte]]
  var R_bytes {.noInit.} : array[8, array[32, byte]]
  var A_bytes {.noInit.} : array[32, byte]

  var L_side {.noInit.} : array[8, EC_P]
  var R_side {.noInit.} : array[8, EC_P]

  var A_inter {.noInit.} : matchingOrderBigInt(Banderwagon)
  var A_fr {.noInit.} : Fr[Banderwagon]

  var idx : int = 0

  for i in 0 ..< 8:
    for j in 0 ..< 32:
      L_bytes[i][j] = src[idx]
      idx = idx + 1

  for i in 0 ..< 8:
    for j in 0 ..< 32:
      R_bytes[i][j] = src[idx]
      idx = idx + 1

  for i in 0 ..< 32:
    A_bytes[i] = src[idx]
    idx = idx + 1

  var i : int = 0
  for item in L_bytes.items():
    let stat = L_side[i].deserialize(item)
    doAssert stat == cttCodecEcc_Success, "Deserialization failure!"
    i = i + 1

  discard L_bytes

  doAssert i == 8, "Should be 8!"

  i  = 0
  for item in R_bytes.items():
    let stat = R_side[i].deserialize(item)
    doAssert stat == cttCodecEcc_Success, "Deserialization failure!"
    i = i + 1

  discard R_bytes

  doAssert i == 8, "Should be 8!"

  let stat2 = A_inter.deserialize_scalar(A_bytes, littleEndian)
  doAssert stat2 == cttCodecScalar_Success, "Scalar Deserialization failure!"

  discard A_bytes

  dst.L_vector = L_side
  dst.R_vector = R_side

  A_fr.fromBig(A_inter)

  dst.A_scalar = A_fr

  res = true
  return res

# ############################################################
#
# IPA proof equality checker
#
# ############################################################

func isIPAProofEqual* (p1: IPAProof, p2: IPAProof) : bool =
  var res {.noInit.}: bool
  const num_rounds = 8
  res = true
  if p1.L_vector.len != p2.R_vector.len:
    res = false

  if p1.R_vector.len != p2.R_vector.len:
    res = false

  if p1.L_vector.len != p1.R_vector.len:
    res = false

  for i in 0 ..< num_rounds:
    var exp_li = p1.L_vector[i]
    var exp_ri = p1.R_vector[i]

    var got_li = p2.L_vector[i]
    var got_ri = p2.R_vector[i]

    if not(exp_li == got_li).bool():
      res = false

    if not(exp_ri == got_ri).bool():
      res = false

  if not(p1.A_scalar == p2.A_scalar).bool():
    res = false

  else:
    res = true
  return res
