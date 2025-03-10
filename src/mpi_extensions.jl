module MPIExtensions

using MPI
import MPI: Buffer, Comm, MPI_Comm, MPIPtr, MPI_Request, Request, RBuffer, libmpi, Op, MPI_Op, MPI_Datatype, @mpichk,
            free, Allreduce!, IN_PLACE
import Base: wait
import MPI: Wait!, Waitall!
import Flux: cpu, gpu
import CUDA: CuArray

const mpi_is_cuda_aware = Ref(false)

function __init__()
    # If using `mpi_is_cuda_aware` anywhere use the @static macro
    # since we anyways need to recompile the code when MPI
    # implementation changes
    mpi_is_cuda_aware[] = MPI.has_cuda()
    if !mpi_is_cuda_aware[]
        @warn "MPI Implementation is not CUDA Aware"
    end
end

"""
    Allreduce!(v, op, comm)

Perform `MPI.Allreduce!` ensuring that CuArrays are safely transfered to
CPU if CUDA-aware MPI is unavailable.
"""
function Allreduce!(v::CuArray, op::Any, comm::MPI_Comm)
    @static if !mpi_is_cuda_aware[]
        v = cpu(v)
    end
    MPI.Allreduce!(v, op, comm)
    @static if !mpi_is_cuda_aware[]
        v = gpu(v)
    end
    return v
end

"""
    Bcast!(v, op, comm)

Perform `MPI.Bcast!` ensuring that CuArrays are safely transfered to
CPU if CUDA-aware MPI is unavailable.
"""
function Bcast!(v::CuArray, root::Integer, comm::MPI_Comm)
    @static if !mpi_is_cuda_aware[]
        v = cpu(v)
    end
    MPI.Bcast!(v, root, comm)
    @static if !mpi_is_cuda_aware[]
        v = gpu(v)
    end
    return v
end

"""
    Reduce!(v, op, comm)

Perform `MPI.Reduce!` ensuring that CuArrays are safely transfered to
CPU if CUDA-aware MPI is unavailable.
"""
function Reduce!(v::CuArray, op::Any, root::Integer, comm::MPI_Comm)
    @static if !mpi_is_cuda_aware[]
        v = cpu(v)
    end
    MPI.Reduce!(v, op, root, comm)
    @static if !mpi_is_cuda_aware[]
        v = gpu(v)
    end
    return v
end

"""
    JuliaTaskRequest

Mostly a hack to work around asynchronous MPI calls using CuArray.

!!! warn
    This is mostly an internal implementation detail and might be removed
    without any deprecation warning
"""
mutable struct JuliaTaskRequest
    task::Any
end

wait(req::JuliaTaskRequest) = wait(req.task)
Wait!(req::JuliaTaskRequest) = wait(req)
Waitall!(reqs::Vector{JuliaTaskRequest}) = wait.(reqs)

"""
    Iallreduce!(sendbuf, recvbuf, op, comm)
    Iallreduce!(sendrecvbuf, op, comm)

Performs non-blocking elementwise reduction using the operator `op` on the buffer `sendbuf`.
`sendbuf` can also be a scalar, in which case `recvbuf` will be a value of the same type.

`recvbuf` and an MPI_Request object are returned. The value in `recvbuf` is only valid after
the request has been completed. (`MPI.Wait!`)
"""
function Iallreduce!(rbuf::RBuffer, op::Union{Op,MPI_Op}, comm::Comm)
    if rbuf.recvdata isa CuArray
        # Iallreduce! is segfaulting for CuArray. So a hack to circumvent it.
        task = @async Allreduce!(rbuf, op, comm)
        return rbuf.recvdata, JuliaTaskRequest(task)
    else
        req = Request()
        # int MPI_Iallreduce(const void *sendbuf, void *recvbuf, int count,
        #                    MPI_Datatype datatype, MPI_Op op, MPI_Comm comm,
        #                    MPI_Request * request)
        @mpichk ccall((:MPI_Iallreduce, libmpi), Cint,
                      (MPIPtr, MPIPtr, Cint, MPI_Datatype, MPI_Op, MPI_Comm, Ptr{MPI_Request}), rbuf.senddata,
                      rbuf.recvdata, rbuf.count, rbuf.datatype, op, comm, req)
        req.buffer = rbuf
        finalizer(free, req)
        return rbuf.recvdata, req
    end
end

Iallreduce!(rbuf::RBuffer, op, comm::Comm) = Iallreduce!(rbuf, Op(op, eltype(rbuf)), comm)

Iallreduce!(sendbuf, recvbuf, op, comm::Comm) = Iallreduce!(RBuffer(sendbuf, recvbuf), op, comm)

Iallreduce!(buf, op, comm::Comm) = Iallreduce!(IN_PLACE, buf, op, comm)

"""
    Ibcast!(buf, root, comm)

Non-blocking broadcast of the buffer `buf` to all processes in `comm`.

`recvbuf` and an MPI_Request object are returned. The value in `recvbuf` is only valid after
the request has been completed. (`MPI.Wait!`)
"""
function Ibcast!(buf::Buffer, root::Integer, comm::Comm)
    req = Request()
    # int MPI_Ibcast(void *buffer, int count, MPI_Datatype datatype, int root,
    #                MPI_Comm comm, MPI_Request *request)
    @mpichk ccall((:MPI_Ibcast, libmpi), Cint, (MPIPtr, Cint, MPI_Datatype, Cint, MPI_Comm, Ptr{MPI_Request}), buf.data,
                  buf.count, buf.datatype, root, comm, req)
    req.buffer = buf
    finalizer(free, req)
    return buf.data, req
end

Ibcast!(buf, root::Integer, comm::Comm) = Ibcast!(Buffer(buf), root, comm)

end
