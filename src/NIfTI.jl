# NIfTI.jl
# Methods for reading NIfTI MRI files in Julia

# Copyright (C) 2013   Simon Kornblith

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

module NIfTI

using StrPack
import Base.getindex, Base.size, Base.ndims, Base.length, Base.endof, Base.write
export NIVolume, niread, niwrite, voxel_size, time_step, vox, getaffine, setaffine

@struct type NIfTI1Header
    sizeof_hdr::Int32

    data_type::ASCIIString(10)
    db_name::ASCIIString(18)
    extents::Int32
    session_error::Int16
    regular::Int8

    dim_info::Int8
    dim::Vector{Int16}(8)
    intent_p1::Float32
    intent_p2::Float32
    intent_p3::Float32
    intent_code::Int16
    datatype::Int16
    bitpix::Int16
    slice_start::Int16
    pixdim::Vector{Float32}(8)
    vox_offset::Float32
    scl_slope::Float32
    scl_inter::Float32
    slice_end::Int16
    slice_code::Int8
    xyzt_units::Int8
    cal_max::Float32
    cal_min::Float32
    slice_duration::Float32
    toffset::Float32

    glmax::Int32
    glmin::Int32

    descrip::ASCIIString(80)
    aux_file::ASCIIString(24)

    qform_code::Int16
    sform_code::Int16
    quatern_b::Float32
    quatern_c::Float32
    quatern_d::Float32
    qoffset_x::Float32
    qoffset_y::Float32
    qoffset_z::Float32

    srow_x::Vector{Float32}(4)
    srow_y::Vector{Float32}(4)
    srow_z::Vector{Float32}(4)

    intent_name::ASCIIString(16)

    magic::ASCIIString(4)
end align_packed

type NIfTI1Extension
    ecode::Int32
    edata::Vector{Uint8}
end

type NIVolume{T<:Number,N} <: AbstractArray{T,N}
    header::NIfTI1Header
    extensions::Vector{NIfTI1Extension}
    raw::Array{T,N}

    NIVolume(header::NIfTI1Header, extensions::Vector{NIfTI1Extension}, raw::Array{T,N}) =
        niupdate(new(header, extensions, raw))
end
NIVolume{T<:Number,N}(header::NIfTI1Header, extensions::Vector{NIfTI1Extension}, raw::Array{T,N}) =
    NIVolume{T,N}(header, extensions, raw)
NIVolume{T<:Number,N}(header::NIfTI1Header, raw::Array{T,N}) =
    NIVolume{T,N}(header, NIfTI1Extension[], raw)

const SIZEOF_HDR = int32(348)

const NIfTI_DT_BITSTYPES = (Int16=>Type)[
    int16(2) => Uint8,
    int16(4) => Int16,
    int16(8) => Int32,
    int16(16) => Float32,
    int16(32) => Complex64,
    int16(64) => Float64,
    int16(256) => Int8,
    int16(512) => Uint16, 
    int16(768) => Uint32,
    int16(1024) => Int64,
    int16(1280) => Uint64,
    int16(1792) => Complex128
]
const NIfTI_DT_BITSTYPES_REVERSE = (Type=>Int16)[]
for (k, v) in NIfTI_DT_BITSTYPES
    NIfTI_DT_BITSTYPES_REVERSE[v] = k
end

# Conversion factors to mm/ms
# http://nifti.nimh.nih.gov/nifti-1/documentation/nifti1fields/nifti1fields_pages/xyzt_units.html
const SPATIAL_UNIT_MULTIPLIERS = [
    1000,   # 1 => NIfTI_UNITS_METER
    1,      # 2 => NIfTI_UNITS_MM
    0.001   # 3 => NIfTI_UNITS_MICRON
]
const TIME_UNIT_MULTIPLIERS = [
    1000,   # NIfTI_UNITS_SEC
    1,      # NIfTI_UNITS_MSEC
    0.001,  # NIfTI_UNITS_USEC
    1,      # NIfTI_UNITS_HZ
    1,      # NIfTI_UNITS_PPM
    1       # NIfTI_UNITS_RADS
]

# Always in mm
voxel_size(header::NIfTI1Header) =
    header.pixdim[2:min(header.dim[1], 3)+1] * SPATIAL_UNIT_MULTIPLIERS[header.xyzt_units & int8(3)]

# Always in ms
time_step(header::NIfTI1Header) =
    header.pixdim[5] * TIME_UNIT_MULTIPLIERS[header.xyzt_units >> int8(3)]

function to_dim_info(dim_info::(Integer, Integer, Integer))
    if dim_info[1] > 3 || dim_info[1] < 0
        error("Invalid frequency dimension $(dim_info[1])")
    elseif dim_info[2] > 3 || dim_info[2] < 0
        error("Invalid phase dimension $(dim_info[2])")
    elseif dim_info[3] > 3 || dim_info[3] < 0
        error("Invalid slice dimension $(dim_info[3])")
    end

    int8(dim_info[1] | (dim_info[2] << int8(2)) | (dim_info[3] << int8(4)))
end

# Returns or sets dim_info as a tuple whose values are the frequency, phase, and slice dimensions
dim_info(header::NIfTI1Header) = (header.dim_info & int8(3), (header.dim_info >> 2) & int8(3),
    (header.dim_info >> 4) & int8(3))
dim_info{T <: Integer}(header::NIfTI1Header, dim_info::(T, T, T)) =
    header.dim_info = to_dim_info(dim_info)

# Gets dim to be used in header
function nidim(x::Array)
    dim = ones(Int16, 8)
    dim[1] = ndims(x)
    dim[2:dim[1]+1] = [size(x)...]
    dim
end

# Gets datatype to be used in header
function nidatatype(t::Type)
    t = get(NIfTI_DT_BITSTYPES_REVERSE, t, nothing)
    if t == nothing
        error("Unsupported data type $T")
    end
    t
end

# Gets the size of a type in bits
nibitpix(t::Type) = int16(sizeof(t)*8)

# Convert a NIfTI header to a 4x4 affine transformation matrix
function getaffine(h::NIfTI1Header)
    pixdim = float64(h.pixdim)
    # See documentation at
    # http://nifti.nimh.nih.gov/nifti-1/documentation/nifti1fields/nifti1fields_pages/qsform.html
    if h.sform_code > 0
        # Method 3
        return [
            h.srow_x'
            h.srow_y'
            h.srow_z'
            0 0 0 1
        ]
    elseif h.qform_code > 0
        # Method 2
        # http://nifti.nimh.nih.gov/nifti-1/documentation/nifti1fields/nifti1fields_pages/quatern.html
        b = float32(h.quatern_b)
        c = float32(h.quatern_c)
        d = float32(h.quatern_d)
        a = sqrt(1 - b*b - c*c - d*d)
        A = [
            a*a+b*b-c*c-d*d   2*b*c-2*a*d       2*b*d+2*a*c
            2*b*c+2*a*d       a*a+c*c-b*b-d*d   2*c*d-2*a*b
            2*b*d-2*a*c       2*c*d+2*a*b       a*a+d*d-c*c-b*b
        ]
        B = [
            pixdim[2]
            pixdim[3]
            pixdim[1]*pixdim[4]
        ]
        return vcat(hcat(A*B, [
            h.qoffset_x
            h.qoffset_y
            h.qoffset_z
        ]), [0 0 0 1])
    elseif h.qform_code == 0
        # Method 1
        return float32([
             pixdim[2] 0         0          0 0
                       0 pixdim[3]          0 0
                       0         0  bitpix[4] 0
                       0         0          0 1
        ])
    end
end

# Set affine matrix of NIfTI header
function setaffine{T}(h::NIfTI1Header, affine::Array{T,2})
    size(affine, 1) == size(affine, 2) == 4 ||
        error("affine matrix must be 4x4")
    affine[4, 1] == affine[4, 2] == affine[4, 3] == 0 && affine[4, 4] == 1 ||
        error("last row of affine matrix must be [0 0 0 1]")
    h.qform_code = zero(Int16)
    h.sform_code = one(Int16)
    h.pixdim[1] = zero(Float32)
    h.quatern_b = zero(Float32)
    h.quatern_c = zero(Float32)
    h.quatern_d = zero(Float32)
    h.qoffset_x = zero(Float32)
    h.qoffset_y = zero(Float32)
    h.qoffset_z = zero(Float32)
    h.srow_x = float32(vec(affine[1, :]))
    h.srow_y = float32(vec(affine[2, :]))
    h.srow_z = float32(vec(affine[3, :]))
    h
end

# Constructor
function NIVolume{T <: Number}(
# Optional MRI volume; if not given, an empty volume is used
raw::Array{T}=Int16[],
extensions::Union(Vector{NIfTI1Extension}, Nothing)=nothing;

# Fields specified as UNUSED in NIfTI1 spec
data_type::String="", db_name::String="", extents::Integer=int32(0),
session_error::Integer=int16(0), regular::Integer=int8(0), glmax::Integer=int32(0),
glmin::Integer=int16(0),

# The frequency encoding, phase encoding and slice dimensions.
dim_info::NTuple{3, Integer}=(0, 0, 0),
# Describes data contained in the file; for valid values, see
# http://nifti.nimh.nih.gov/nifti-1/documentation/nifti1fields/nifti1fields_pages/group__NIfTI1__INTENT__CODES.html
intent_p1::Real=0f0, intent_p2::Real=0f0, intent_p3::Real=0f0,
intent_code::Integer=int16(0), intent_name::String="",
# Information about which slices were acquired, in case the volume has been padded
slice_start::Integer=int16(0), slice_end::Integer=int16(0), slice_code::Int8=int8(0),
# The size of each voxel and the time step. These are formulated in mm unless xyzt_units is
# explicitly specified
voxel_size::NTuple{3, Real}=(1f0, 1f0, 1f0), time_step::Real=0f0, xyzt_units::Int8=int8(18),
# Slope and intercept by which volume shoudl be scaled
scl_slope::Real=1f0, scl_inter::Real=0f0,
# These describe how data should be scaled when displayed on the screen. They are probably
# rarely used
cal_max::Real=0f0, cal_min::Real=0f0,
# The amount of time taken to acquire a slice
slice_duration::Real=0f0,
# Indicates a non-zero start point for time axis
toffset::Real=0f0,

# "Any text you like"
descrip::String="",
# Name of auxiliary file
aux_file::String="",

# Parameters for Method 2. See the NIfTI spec
qfac::Float32=0f0, quatern_b::Real=0f0, quatern_c::Real=0f0, quatern_d::Real=0f0,
qoffset_x::Real=0f0, qoffset_y::Real=0f0, qoffset_z::Real=0f0,
# Orientation matrix for Method 3
orientation::Union(Matrix{Float32}, Nothing)=nothing)
    local t
    if isempty(raw)
        raw = Int16[]
        t = Int16
    else
        t = T
    end

    if extensions == nothing
        extensions = NIfTI1Extension[]
    end

    method2 = qfac != 0 || quatern_b != 0 || quatern_c != 0 || quatern_d != 0 || qoffset_x != 0 ||
        qoffset_y != 0 || qoffset_z != 0
    method3 = orientation != nothing

    if method2 && method3
        error("Orientation parameters for Method 2 and Method 3 are mutually exclusive")
    end

    if method3
        if size(orientation) != (3, 4)
            error("Orientation matrix must be of dimensions (3, 4)")
        end
    else
        orientation = zeros(Float32, 3, 4)
    end

    if slice_start == 0 && slice_end == 0 && dim_info[3] != 0
        slice_start = 0
        slice_end = size(raw, dim_info[3]) - 1
    end

    NIVolume(NIfTI1Header(SIZEOF_HDR, data_type, db_name, int32(extents), int16(session_error),
        int8(regular), to_dim_info(dim_info), nidim(raw), float32(intent_p1), float32(intent_p2),
        float32(intent_p3), int16(intent_code), nidatatype(t), nibitpix(t), 
        int16(slice_start), float32([qfac, voxel_size..., time_step, 0, 0, 0]), float32(352),
        float32(scl_slope), float32(scl_inter), int16(slice_end), int8(slice_code),
        int8(xyzt_units), float32(cal_max), float32(cal_min), float32(slice_duration),
        float32(toffset), int32(glmax), int32(glmin), descrip, aux_file, int16(method2 || method3),
        int16(method3), float32(quatern_b), float32(quatern_c), float32(quatern_d),
        float32(qoffset_x), float32(qoffset_y), float32(qoffset_z), orientation[1, :][:],
        orientation[2, :][:], orientation[3, :][:], intent_name, "n+1"), extensions, raw)
end

# Calculates the size of a NIfTI extension
esize(ex::NIfTI1Extension) = 8 + iceil(length(ex.edata)/16)*16

# Validates the header of a volume and updates it to match the volume's contents
function niupdate{T}(vol::NIVolume{T})
    if length(vol.header.srow_x) != 4
        error("srow_x must have 4 values; $(length(srow_x)) encountered")
    elseif length(vol.header.srow_y) != 4
        error("srow_y must have 4 values; $(length(srow_y)) encountered")
    elseif length(vol.header.srow_z) != 4
        error("srow_z must have 4 values; $(length(srow_z)) encountered")
    end

    vol.header.sizeof_hdr = SIZEOF_HDR
    vol.header.dim = nidim(vol.raw)
    vol.header.datatype = nidatatype(T)
    vol.header.bitpix = nibitpix(T)
    vol.header.vox_offset = isempty(vol.extensions) ? int32(352) :
        float32(reduce((v, ex) -> v + esize(ex), SIZEOF_HDR, vol.extensions))
    vol
end

# Write the NIfTI header
write(io::IO, header::NIfTI1Header) = pack(io, header)

# Avoid method ambiguity
write(io::Base64Pipe, vol::NIVolume{Uint8,1}) = invoke(write, (IO, NIVolume{Uint8,1}), io, vol)

# Write a NIfTI file
function write(io::IO, vol::NIVolume)
    write(io, niupdate(vol).header)
    if isempty(vol.extensions)
        write(io, int32(0))
    else
        for ex in vol.extensions
            sz = esize(ex)
            write(io, int32(sz))
            write(io, int32(ex.ecode))
            write(io, ex.edata)
            write(io, zeros(Uint8, sz - length(ex.edata)))
        end
    end
    write(io, vol.raw)
end

# Convenience function to write a NIfTI file given a patch
function niwrite(path::String, vol::NIVolume)
    io = open(path, "w")
    write(io, vol)
    close(io)
end

# Read header from a NIfTI file
function read_header(io::IO)
    header = unpack(io, NIfTI1Header)
    if header.sizeof_hdr != SIZEOF_HDR
        error("This is not a NIfTI-1 file")
    end
    if header.dim[1] > 7
        error("Byte swapping not yet supported")
    end
    header
end

# Read extension fields following NIfTI header
function read_extensions(io::IO, header::NIfTI1Header)
    if eof(io)
        return NIfTI1Extension[]
    end

    extension = read(io, Uint8, 4)
    if extension[1] != 1
        return NIfTI1Extension[]
    end

    extensions = NIfTI1Extension[]
    should_bswap = header.dim[1] > 7
    while header.magic == "n+1" ? position(io) < header.vox_offset : !eof(io)
        esize = read(io, Int32)
        ecode = read(io, Int32)
        
        if should_bswap
            esize = bswap(esize)
            ecode = bswap(ecode)
        end

        push!(extensions, NIfTI1Extension(ecode, read(io, Uint8, esize-8)))
    end
    extensions
end

# Read a NIfTI file. The optional mmap argument determines whether the contents are read in full
# (if false) or mmaped from the disk (if true).
function niread(file::String; mmap::Bool=false)
    header_io = open(file, "r")
    header = read_header(header_io)
    extensions = read_extensions(header_io, header)
    dims = tuple(int(header.dim[2:header.dim[1]+1])...)

    if !haskey(NIfTI_DT_BITSTYPES, header.datatype)
        error("Data type $(header.datatype) not yet supported")
    end
    dtype = NIfTI_DT_BITSTYPES[header.datatype]

    local volume
    if header.magic == "n+1"
        if mmap
            volume = mmap_array(dtype, dims, header_io, int(header.vox_offset))
        else
            seek(header_io, int(header.vox_offset))
            volume = read(header_io, dtype, dims)
            @assert eof(header_io)
            close(header_io)
        end
    elseif header.magic == "nil"
        close(header_io)
        volume_io = open(replace(file, r"\.\w+$", "")*".img", "r")
        if mmap
            volume = mmap_array(dtype, dims, volume_io)
        else
            volume = read(volume_io, dtype, dims)
            close(volume_io)
        end
    end

    return NIVolume(header, extensions, volume)
end

# Avoid method ambiguity
getindex{T}(f::NIVolume{T}, x::Real) = invoke(getindex, (typeof(f), Any), f, x)
getindex{T}(f::NIVolume{T}, x::AbstractArray) = invoke(getindex, (typeof(f), Any), f, x)
# Allow file to be indexed like an array, but with indices yielding scaled data
getindex{T}(f::NIVolume{T}, args...) =
    getindex(f.raw, args...) * (f.header.scl_slope != zero(T) ?
                                f.header.scl_slope : zero(T)) + f.header.scl_inter
vox(f::NIVolume, args...) =
    getindex(f, [isa(args[i], Colon) ? (1:size(f.raw, i)) : args[i] + 1 for i = 1:length(args)]...)
size(f::NIVolume) = size(f.raw)
size(f::NIVolume, d) = size(f.raw, d)
ndims(f::NIVolume) = ndims(f.raw)
length(f::NIVolume) = length(f.raw)
endof(f::NIVolume) = endof(f.raw)

end