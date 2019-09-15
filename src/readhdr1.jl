function readhdr1(s::IO, p::AbstractDict)
    # Uncecessary fields
    skip(s, 35)

#    p["header"] = ImageProperties{:header}()
    d = read(s, Int8)
    freqdim!(p, Int(d & Int8(3) + 1))
    phasedim!(p, Int((d >> 2) & Int8(3) + 1))
    slicedim!(p, Int((d >> 4) + 1))
    N = Int(read(s, Int16))
    sz = ([Int(read(s, Int16)) for i in 1:N]...,)
    skip(s, (7-N)*2)  # skip filler dims

    # intent parameters
    intentparams!(p, Tuple(float.(read!(s, Vector{Int32}(undef, 3))))::NTuple{3,Float64})
    intent!(p, num2intent(read(s, Int16)))
    T = get(NiftiDatatypes, read(s, Int16), UInt8)

    # skip bitpix
    skip(s, 2)
    slicestart!(p, Int(read(s, Int16)) + 1)  # to 1 based indexing

    qfac = Float64(read(s, Float32))
    pixdim = (Float64.(read!(s, Vector{Float32}(undef, N)))...,)

    skip(s, (7-N)*4)  # skip filler dims

    dataoffset!(p, Int(read(s, Float32)))
    scaleslope!(p, Float64(read(s, Float32)))
    scaleintercept!(p, Float64(read(s, Float32)))
    sliceend!(p, Int(read(s, Int16) + 1))  # to 1 based indexing
    slicecode!(p, numeric2slicecode(read(s, Int8)))

    xyzt_units = Int32(read(s, Int8))
    sp_units = get(NiftiUnits, xyzt_units & 0x07, 1)


    calmax!(p, read(s, Float32))
    calmin!(p, read(s, Float32))
    sliceduration!(p, read(s, Float32))
    toffset = read(s, Float32)

    skip(s, 8)
    description!(p, String(read(s, 80)))
    auxfiles!(p, [String(read(s, 24))])

    qformcode!(p, xform(read(s, Int16)))
    sformcode!(p, xform(read(s, Int16)))
    if qformcode(p) == UnkownSpace
        skip(s, 12)  # skip quaternion b/c space is unkown
        qform!(p, MMatrix{4,4,Float64,16}([pixdim[2]         0            0 0
                                                   0 pixdim[3]            0 0
                                                   0         0  pixdim[4] 0
                                                   0         0            0 1]))
        qx = Float64(read(s, Float32))
        qy = Float64(read(s, Float32))
        qz = Float64(read(s, Float32))
        dimnames = orientation(qform(p))
    else
        b = Float64(read(s, Float32))
        c = Float64(read(s, Float32))
        d = Float64(read(s, Float32))
        qx = Float64(read(s, Float32))
        qy = Float64(read(s, Float32))
        qz = Float64(read(s, Float32))
        a = 1 - (b*b + c*c + d*d)
        if a < 1.e-7                   # special case
            a = 1 / sqrt(b*b+c*c+d*d)
            b *= a
            c *= a
            d *= a                   # normalize (b,c,d) vector
            a = zero(Float64)        # a = 0 ==> 180 degree rotation
        else
            a = sqrt(a)              # angle = 2*arccos(a)
        end
        # make sure are positive
        xd = pixdim[1] > 0 ? pixdim[1] : one(Float64)
        yd = pixdim[2] > 0 ? pixdim[2] : one(Float64)
        zd = pixdim[3] > 0 ? pixdim[3] : one(Float64)
        zd = qfac < 0 ? -zd : zd
        qform!(p, MMatrix{4,4,Float64}([[((a*a+b*b-c*c-d*d)*xd),       (2*(b*c-a*d)*yd),       (2*(b*d+a*c)*zd),   qx]'
                                        [     (2*(b*c+a*d )*xd), ((a*a+c*c-b*b-d*d)*yd),       (2*(c*d-a*b)*zd),   qy]'
                                        [      (2*(b*d-a*c)*xd),       (2*(c*d+a*b)*yd), ((a*a+d*d-c*c-b*b)*zd),   qz]'
                                        [                     0,                      0,                      0, qfac]']))

        if sformcode(p) == UnkownSpace
            skip(s, 48)
            p["spacedirections"] = (Tuple(qform(p)[1,1:3]), Tuple(qform(p)[1,1:3]), Tuple(qform(p)[3,1:3]))
            dimnames = orientation(qform(p))
        else
            sform!(p, MMatrix{4,4,Float64}(vcat(Float64.(read!(s, Matrix{Float32}(undef, (1,4)))),
                                                Float64.(read!(s, Matrix{Float32}(undef, (1,4)))),
                                                Float64.(read!(s, Matrix{Float32}(undef, (1,4)))),
                                                Float64[0, 0, 0, 1]')))
            p["spacedirections"] = (Tuple(sform(p)[1,1:3]), Tuple(sform(p)[1,1:3]), Tuple(sform(p)[3,1:3]))
            dimnames = orientation(sform(p))
        end
    end
    axs = (range(qx, step=pixdim[1], length=sz[1])*sp_units,)
    if N > 1
        axs = (axs..., range(qy, step=pixdim[2], length=sz[2])*sp_units)
    end
    if N > 2
        axs = (axs..., range(qz, step=pixdim[3], length=sz[3])*sp_units)
    end
    if N > 3
        dimnames = (dimnames..., :time)
        tu = get(NiftiUnits, xyzt_units & 0x38, 1)
        axs = (axs..., range(toffset, step=pixdim[4], length=sz[4])*tu)
    end
    if N > 4
        dimnames = (dimnames..., intentaxis(intent)...)
        axs = (axs..., map(i->range(one(Float64), step=pixdim[i], lenght=sz[i]), 5:N)...)
    end

    extension!(p, read(s, p, NiftiExtension))

    return ArrayInfo{T}(NamedTuple{dimnames}(axs), p)
end
