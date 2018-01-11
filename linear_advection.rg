import "regent"
local C = regentlib.c
local MATH = terralib.includec("math.h")

require("global_const")
require("refinement_bits")

-- model specific local constants
local CFL = 0.5
local U = 1.0
local MAX_NX = 640
local MIN_DX = 1.0 / MAX_NX
local MAX_GRAD = 1.0

-- required global constants
DT = CFL * MIN_DX / U

-- model specific fields must be in fspace's CellValues and FaceValues

fspace CellValues
{
  phi : double
}

fspace FaceValues
{
  flux : double,
  grad : double
}

-- model specific tasks must implement following API:
-- task initializeCells(cell_region: region(ispace(int1d), CellValues))
-- task calculateFlux(num_cells : int64,
--                    dx : double,
--                    dt : double,
--                    cells: region(ispace(int1d), CellValues),
--                    faces: region(ispace(int1d), FaceValues))
-- task applyFlux(dx : double,
--                dt : double,
--                cells: region(ispace(int1d), CellValues),
--                faces: region(ispace(int1d), FaceValues))
-- task writeCells(num_cells : int64,
--                 cells: region(ispace(int1d), CellValues))

task initializeCells(cell_region: region(ispace(int1d), CellValues))
where
  writes(cell_region.phi)
do
  var size : int64 = cell_region.ispace.bounds.hi - cell_region.ispace.bounds.lo + 1
  for cell in cell_region.ispace do
    if [int64](cell) < (size/2) then
      cell_region[cell].phi = 1.0
    else
      cell_region[cell].phi = 0.0
    end
  end
  C.printf("initializeCells %d cells\n", size)
end

-- hard coded linear advection with Lax-Friedrichs for now, metaprog soon
task applyFlux(dx : double,
               dt : double,
               cells: region(ispace(int1d), CellValues),
               faces: region(ispace(int1d), FaceValues))
where
  reads(cells.phi,
        faces.flux),
  writes(cells.phi)
do
  var face_index : int64 = faces.ispace.bounds.lo
  for cell in cells do
    cells[cell].phi = cells[cell].phi - dt * (faces[face_index+1].flux - faces[face_index].flux) / dx
    face_index = face_index + 1
  end
end

-- linear advection with Lax-Friedrichs
task calculateFlux(num_cells : int64,
                   dx : double,
                   dt : double,
                   cells: region(ispace(int1d), CellValues),
                   faces: region(ispace(int1d), FaceValues))
where
  reads(cells.phi,
        faces.flux),
  writes(faces.flux)
do
  var vel : double = U
  var left_boundary_face : int64 = faces.ispace.bounds.lo
  var right_boundary_face : int64 = faces.ispace.bounds.hi

  var left_boundary_cell : int64 = cells.ispace.bounds.lo
  var right_boundary_cell : int64 = cells.ispace.bounds.hi

  var start_face : int64 = left_boundary_face
  var stop_face : int64 = right_boundary_face + 1

  if left_boundary_cell == 0 then
    start_face  = start_face + 1
  end
  if right_boundary_cell == (num_cells - 1) then
    stop_face  = stop_face - 1
  end

  -- loop on inner faces
  var cell_index : int64 = left_boundary_cell
  for face = start_face, stop_face do
    var left : double = cells[cell_index].phi
    cell_index = cell_index + 1
    var right : double = cells[cell_index].phi
    var flux : double = 0.5 * vel * (left + right) +0.5 * dx * (left - right)/dt
    faces[face].flux = flux
  end

  -- boundary conditions: hold end cells constant in time
  if left_boundary_cell == 0 then
    faces[0].flux = faces[1].flux
  end
  if right_boundary_cell == (num_cells - 1) then
    faces[right_boundary_face].flux = faces[right_boundary_face-1].flux
  end
end

task writeCells(nx : int64,
                cells: region(ispace(int1d), CellValues))
where
  reads(cells.phi)
do
  var first_cell : int64 = cells.ispace.bounds.lo
  var last_cell : int64 = cells.ispace.bounds.hi
  var buf : &int8
  buf = [&int8](C.malloc(40))
  C.sprintf(buf, "linear.%d.txt", nx)
  var fp = C.fopen(buf,"w")
  for cell in cells do
    C.fprintf(fp, "%f\n", cells[cell].phi)
  end
  C.fclose(fp)
  C.free([&opaque](buf))
end


task printCells(cell_region: region(ispace(int1d), CellValues))
where
  reads(cell_region.phi)
do
  C.printf("phi: ")
  for cell in cell_region do
    C.printf("%f ", cell_region[cell].phi)
  end
  C.printf("\n")
end


task calculateGradient(num_cells : int64,
                   dx : double,
                   cells: region(ispace(int1d), CellValues),
                   faces: region(ispace(int1d), FaceValues))
where
  reads(cells.phi,
        faces.grad),
  writes(faces.grad)
do
  var vel : double = U
  var left_boundary_face : int64 = faces.ispace.bounds.lo
  var right_boundary_face : int64 = faces.ispace.bounds.hi

  var left_boundary_cell : int64 = cells.ispace.bounds.lo
  var right_boundary_cell : int64 = cells.ispace.bounds.hi

  var start_face : int64 = left_boundary_face
  var stop_face : int64 = right_boundary_face + 1

  if left_boundary_cell == 0 then
    start_face  = start_face + 1
  end
  if right_boundary_cell == (num_cells - 1) then
    stop_face  = stop_face - 1
  end

  -- loop on inner faces
  var cell_index : int64 = left_boundary_cell
  for face = start_face, stop_face do
    var left : double = cells[cell_index].phi
    cell_index = cell_index + 1
    var right : double = cells[cell_index].phi
    var grad : double = (right - left) / dx
    faces[face].grad = grad
  end

  -- boundary conditions: hold end cells constant in time
  if left_boundary_cell == 0 then
    faces[0].grad = 0.0
  end
  if right_boundary_cell == (num_cells - 1) then
    faces[right_boundary_face].grad = 0.0
  end
end

task printFaces(faces: region(ispace(int1d), FaceValues))
where
  reads(faces.grad)
do
  C.printf("grad: ")
  for face in faces do
    C.printf("%d:%f ", face, faces[face].grad)
  end
  C.printf("\n")
end

task flagRegrid(blocks: region(ispace(int1d), RefinementBits),
                faces: region(ispace(int1d), FaceValues))
                
where
  reads(faces.grad),
  reads writes(blocks.needsRefinement)
do
  var first_face : int64 = faces.ispace.bounds.lo

  var start_block : int64 = blocks.ispace.bounds.lo
  var stop_block : int64 = blocks.ispace.bounds.hi + 1

  for block = start_block, stop_block do
    C.printf("block %d\n", block)
    var start_face : int64 = first_face + (CELLS_PER_BLOCK_X) * (block - start_block)
    var stop_face : int64 = start_face + CELLS_PER_BLOCK_X + 1
    for face = start_face, stop_face do
      if MATH.fabs(faces[face].grad) > MAX_GRAD then
        blocks[block].needsRefinement = true
      end
      C.printf("face %d %f %d\n", face, faces[face].grad, blocks[block].needsRefinement)
    end -- for face
  end -- for block
end
