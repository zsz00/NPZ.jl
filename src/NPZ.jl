__precompile__()
module NPZ

# NPZ file format is described in
# https://github.com/numpy/numpy/blob/v1.7.0/numpy/lib/format.py

using ZipFile, Compat, FileIO

@static if VERSION >=  v"0.7.0-DEV.2575"
    import Base.CodeUnits
else
    # CodeUnits not yet supported by Compat but not needed in julia 0.6...
    # codeunits function in Compat returns uintX instead of codeunits
    # therefore this 'stump' type should work
    abstract type CodeUnits{U, S} end
end

export npzread, npzwrite

const NPYMagic = UInt8[0x93, 'N', 'U', 'M', 'P', 'Y']
const ZIPMagic = UInt8['P', 'K', 3, 4]
const Version = UInt8[1, 0]

const MaxMagicLen = maximum(length.([NPYMagic, ZIPMagic]))

const TypeMaps = [
    ("b1", Bool),
    ("i1", Int8),
    ("i2", Int16),
    ("i4", Int32),
    ("i8", Int64),
    ("u1", UInt8),
    ("u2", UInt16),
    ("u4", UInt32),
    ("u8", UInt64),
    ("f2", Float16),
    ("f4", Float32),
    ("f8", Float64),
    ("c8", Complex{Float32}),
    ("c16", Complex{Float64}),
]
const Numpy2Julia = Dict{String, DataType}()
for (s,t) in TypeMaps
    Numpy2Julia[s] = t
end

const Julia2Numpy = Dict{DataType, String}()

@static if VERSION >= v"0.4.0"
    function __init__()
        for (s,t) in TypeMaps
            Julia2Numpy[t] = s
        end
    end
else
    for (s,t) in TypeMaps
        Julia2Numpy[t] = s
    end
end

# Julia2Numpy is a dictionary that uses Types as keys.
# This is problematic for precompilation because the
# hash of a Type changes everytime Julia is run.
# The hash of the keys when NPZ is precompiled will
# not be the same as when it is later run. This can
# be fixed by rehashing the Dict when the module is
# loaded.

readle(ios::IO, ::Type{T}) where T = ltoh(read(ios, T)) # ltoh is inverse of htol

function writecheck(io::IO, x::Any)
    n = write(io, x) # returns size in bytes
    n == sizeof(x) || error("short write") # sizeof is size in bytes
end

# Endianness only pertains to multi-byte things
writele(ios::IO, x::AbstractVector{UInt8}) = writecheck(ios, x)
writele(ios::IO, x::AbstractVector{CodeUnits{UInt8, <:Any}}) = writecheck(ios, x)
# codeunits returns vector of CodeUnits in 7+, uint in 6
writele(ios::IO, x::AbstractString) = writele(ios, codeunits(x))

writele(ios::IO, x::UInt16) = writecheck(ios, htol(x))

function parsechar(s::AbstractString, c::Char)
    firstchar = s[firstindex(s)]
    if  firstchar != c
        error("parsing header failed: expected character '$c', found '$firstchar'")
    end
    SubString(s, nextind(s, 1))
end

function parsestring(s::AbstractString)
    s = parsechar(s, '\'')
    parts = split(s, '\'', limit = 2)
    length(parts) != 2 && error("parsing header failed: malformed string")
    parts[1], parts[2]
end

function parsebool(s::AbstractString)
    if SubString(s, firstindex(s), thisind(s, 4)) == "True"
        return true, SubString(s, nextind(s, 4))
    elseif SubString(s, firstindex(s), thisind(s, 5)) == "False"
        return false, SubString(s, nextind(s, 5))
    end
    error("parsing header failed: excepted True or False")
end

function parseinteger(s::AbstractString)
    isdigit(s[firstindex(s)]) || error("parsing header failed: no digits")
    tail_idx = findfirst(c -> !isdigit(c), s)
    if tail_idx == nothing
        intstr = SubString(s, firstindex(s))
    else
        intstr = SubString(s, firstindex(s), prevind(s, tail_idx))
        if s[tail_idx] == 'L' # output of firstindex should be a valid code point
            tail_idx = nextind(s, tail_idx)
        end
    end
    n = parse(Int, intstr)
    return n, SubString(s, tail_idx)
end

function parsetuple(s::AbstractString)
    s = parsechar(s, '(')
    tup = Int[]
    while true
        s = strip(s)
        if s[firstindex(s)] == ')'
            break
        end
        n, s = parseinteger(s)
        push!(tup, n)
        s = strip(s)
        if s[firstindex(s)] == ')'
            break
        end
        s = parsechar(s, ',')
    end
    s = parsechar(s, ')')
    Tuple(tup), s
end

function parsedtype(s::AbstractString)
    dtype, s = parsestring(s)
    c = dtype[firstindex(s)]
    t = SubString(dtype, nextind(s, 1))
    if c == '<'
        toh = ltoh
    elseif c == '>'
        toh = ntoh
    elseif c == '|'
        toh = identity
    else
        error("parsing header failed: unsupported endian character $c")
    end
    if !haskey(Numpy2Julia, t)
        error("parsing header failed: unsupported type $t")
    end
    (toh, Numpy2Julia[t]), s
end

struct Header{T,N,F<:Function}
    descr::F
    fortran_order::Bool
    shape::NTuple{N,Int}
end

Header{T}(descr::F, fortran_order, shape::NTuple{N,Int}) where {T,N,F} = Header{T,N,F}(descr, fortran_order, shape)
Base.size(hdr::Header) = hdr.shape
Base.eltype(hdr::Header{T}) where T = T
Base.ndims(hdr::Header{T,N}) where {T,N} = N

function parseheader(s::AbstractString)
    s = parsechar(s, '{')

    dict = Dict{String,Any}()
    T = Any
    for _ in 1:3
        s = strip(s)
        key, s = parsestring(s)
        s = strip(s)
        s = parsechar(s, ':')
        s = strip(s)
        if key == "descr"
            (descr, T), s = parsedtype(s)
            dict[key] = descr
        elseif key == "fortran_order"
            dict[key], s = parsebool(s)
        elseif key == "shape"
            dict[key], s = parsetuple(s)
        else
            error("parsing header failed: bad dictionary key")
        end
        s = strip(s)
        if s[firstindex(s)] == '}'
            break
        end
        s = parsechar(s, ',')
    end
    s = strip(s)
    s = parsechar(s, '}')
    s = strip(s)
    if s != ""
        error("malformed header")
    end
    Header{T}(dict["descr"], dict["fortran_order"], dict["shape"])
end

function readheader(f::IO)
    @compat b = read!(f, Vector{UInt8}(undef, length(NPYMagic)))
    if b != NPYMagic
        error("not a numpy array file")
    end
    @compat b = read!(f, Vector{UInt8}(undef, length(Version)))

    # support for version 2 files
    if b[1] == 1
        hdrlen = UInt32(readle(f, UInt16))
    elseif b[1] == 2 
        hdrlen = UInt32(readle(f, UInt32))
    else
        error("unsupported NPZ version")
    end

    @compat hdr = ascii(String(read!(f, Vector{UInt8}(undef, hdrlen))))
    parseheader(strip(hdr))
end

function _npzreadarray(f, hdr::Header{T}) where {T}
    toh = hdr.descr
    if hdr.fortran_order
        @compat x = map(toh, read!(f, Array{T}(undef, hdr.shape)))
    else
        @compat x = map(toh, read!(f, Array{T}(undef, reverse(hdr.shape))))
        if ndims(x) > 1
            x = permutedims(x, collect(ndims(x):-1:1))
        end
    end
    ndims(x) == 0 ? x[1] : x
end

function npzreadarray(f::IO)
    hdr = readheader(f)
    _npzreadarray(f, hdr)
end

function samestart(a::AbstractVector, b::AbstractVector)
    nb = length(b)
    length(a) >= nb && view(a, 1:nb) == b
end

function _maybetrimext(name::AbstractString)
    fname, ext = splitext(name)
    if ext == ".npy"
        name = fname
    end
    name
end

"""
    npzread(filename::AbstractString, [vars])

Read a variable or a collection of variables from `filename`. 
The input needs to be either an `npy` or an `npz` file.
The optional argument `vars` is used only for `npz` files.
If it is specified, only the matching variables are read in from the file.

!!! note "Zero-dimensional arrays"
    Zero-dimensional arrays are stripped while being read in, and the values that they
    contain are returned. This is a notable difference from numpy, where 
    numerical values are written out and read back in as zero-dimensional arrays.

# Examples

```julia
julia> npzwrite("temp.npz", x = ones(3), y = 3)

julia> npzread("temp.npz") # Reads all variables
Dict{String,Any} with 2 entries:
  "x" => [1.0, 1.0, 1.0]
  "y" => 3

julia> npzread("temp.npz", ["x"]) # Reads only "x"
Dict{String,Array{Float64,1}} with 1 entry:
  "x" => [1.0, 1.0, 1.0]
```
"""
function npzread(filename::AbstractString, vars...)
    # Detect if the file is a numpy npy array file or a npz/zip file.
    f = open(filename)
    @compat b = read!(f, Vector{UInt8}(undef, MaxMagicLen))

    if samestart(b, ZIPMagic)
        fz = ZipFile.Reader(filename)
        data = npzread(fz, vars...)
        close(fz)
    elseif samestart(b, NPYMagic)
        seekstart(f)
        data = npzreadarray(f)
    else
        close(f)
        error("not a NPY or NPZ/Zip file: $filename")
    end
    close(f)
    return data
end

function npzread(dir::ZipFile.Reader, 
    vars = map(f -> _maybetrimext(f.name), dir.files))

    Dict(_maybetrimext(f.name) => npzreadarray(f)
        for f in dir.files 
            if f.name in vars || _maybetrimext(f.name) in vars)
end

"""
    readheader(filename, [vars...])

Return a header or a collection of headers corresponding to each variable contained in `filename`. 
The header contains information about the `eltype` and `size` of the array that may be extracted using 
the corresponding accessor functions.
"""
function readheader(filename::AbstractString, vars...)
    # Detect if the file is a numpy npy array file or a npz/zip file.
    f = open(filename)
    @compat b = read!(f, Vector{UInt8}(undef, MaxMagicLen))

    if samestart(b, ZIPMagic)
        fz = ZipFile.Reader(filename)
        data = readheader(fz, vars...)
        close(fz)
    elseif samestart(b, NPYMagic)
        seekstart(f)
        data = readheader(f)
    else
        close(f)
        error("not a NPY or NPZ/Zip file: $filename")
    end

    close(f)
    return data
end
function readheader(dir::ZipFile.Reader, 
    vars = map(f -> _maybetrimext(f.name), dir.files))

    Dict(_maybetrimext(f.name) => readheader(f)
        for f in dir.files 
            if f.name in vars || _maybetrimext(f.name) in vars)
end

function npzwritearray(
    f::IO, x::AbstractArray{UInt8}, T::DataType, shape)

    if !haskey(Julia2Numpy, T)
        error("unsupported type $T")
    end
    writele(f, NPYMagic)
    writele(f, Version)

    descr =  (ENDIAN_BOM == 0x01020304 ? ">" : "<") * Julia2Numpy[T]
    dict = "{'descr': '$descr', 'fortran_order': True, 'shape': $(Tuple(shape)), }"

    # The dictionary is padded with enough whitespace so that
    # the array data is 16-byte aligned
    n = length(NPYMagic)+length(Version)+2+length(dict)
    pad = (div(n+16-1, 16)*16) - n
    if pad > 0
        dict *= " "^(pad-1) * "\n"
    end

    writele(f, UInt16(length(dict)))
    writele(f, dict)
    if write(f, x) != length(x)
        error("short write")
    end
end

function npzwritearray(f::IO, x::AbstractArray)
    npzwritearray(f, reinterpret(UInt8, vec(x)), eltype(x), size(x))
end

function npzwritearray(f::IO, x::Number)
    npzwritearray(f, reinterpret(UInt8, [x]), typeof(x), ())
end

"""
    npzwrite(filename::AbstractString, x)

Write the variable `x` to the `npy` file `filename`. 
Unlike `numpy`, the extension `.npy` is not appened to `filename`.

!!! warn "Warning"
    Any existing file with the same name will be overwritten.

# Examples

```julia
julia> npzwrite("abc.npy", zeros(3))

julia> npzread("abc.npy")
3-element Array{Float64,1}:
 0.0
 0.0
 0.0
```
"""
function npzwrite(filename::AbstractString, x)
    open(filename, "w") do f
        npzwritearray(f, x)
    end
end

"""
    npzwrite(filename::AbstractString, vars::Dict{<:AbstractString})
    npzwrite(filename::AbstractString, args...; kwargs...)

In the first form, write the variables in `vars` to an `npz` file named `filename`.

In the second form, collect the variables in `args` and `kwargs` and write them all
to `filename`. The variables in `args` are saved with names `arr_0`, `arr_1` 
and so on, whereas the ones in `kwargs` are saved with the specified names.

Unlike `numpy`, the extension `.npz` is not appened to `filename`.

!!! warn "Warning"
    Any existing file with the same name will be overwritten.

# Examples

```julia
julia> npzwrite("temp.npz", Dict("x" => ones(3), "y" => 3))

julia> npzread("temp.npz")
Dict{String,Any} with 2 entries:
  "x" => [1.0, 1.0, 1.0]
  "y" => 3

julia> npzwrite("temp.npz", ones(2,2), x = ones(3), y = 3)

julia> npzread("temp.npz")
Dict{String,Any} with 3 entries:
  "arr_0" => [1.0 1.0; 1.0 1.0]
  "x"     => [1.0, 1.0, 1.0]
  "y"     => 3
```
"""
function npzwrite(filename::AbstractString, vars::Dict{<:AbstractString}) 
    dir = ZipFile.Writer(filename)

    if length(vars) == 0
        @warn "no data to be written to $filename. It might not be possible to read the file correctly."
    end

    for (k, v) in vars
        f = ZipFile.addfile(dir, k * ".npy")
        npzwritearray(f, v)
        close(f)
    end

    close(dir)
end

function npzwrite(filename::AbstractString, args...; kwargs...)
    dkwargs = Dict(string(k) => v for (k,v) in kwargs)
    dargs = Dict("arr_"*string(i-1) => v for (i,v) in enumerate(args))

    d = convert(Dict{String,Any}, merge(dargs, dkwargs))

    npzwrite(filename, d)
end

# support for FileIO
load(file::File{format"NPY"}, vars...) = npzread(filename(file), vars...)
load(file::File{format"NPZ"}, vars...) = npzread(filename(file), vars...)

save(file::File{format"NPY"}, data, vars...) = npzwrite(filename(file), data, vars...)
save(file::File{format"NPZ"}, data, vars...) = npzwrite(filename(file), data, vars...)

end # module
