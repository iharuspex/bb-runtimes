------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--               S Y S T E M . S E C O N D A R Y _ S T A C K                --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 1992-2023, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  This is the HI-E version of this package for CHERI targets

with Ada.Unchecked_Conversion;
with Interfaces.CHERI;

package body System.Secondary_Stack is

   use type System.Parameters.Size_Type;

   function Get_Sec_Stack return SS_Stack_Ptr;
   pragma Import (C, Get_Sec_Stack, "__gnat_get_secondary_stack");
   --  Return the pointer to the secondary stack of the current task.
   --
   --  The package imports this function to permit flexibility in the storage
   --  of secondary stacks pointers to support a range of different ZFP and
   --  other restricted run-time scenarios without needing to recompile the
   --  run-time. A ZFP run-time will typically include a default implementation
   --  suitable for single thread applications (s-sssita.adb). However, users
   --  can replace this implementation by providing their own as part of their
   --  program (for example, if multiple threads need to be supported in a ZFP
   --  application).
   --
   --  Many Ravenscar run-times also use this mechanism to provide switch
   --  between efficient single task and multitask implementations without
   --  depending on System.Soft_Links.
   --
   --  In all cases, the binder will generate a default-sized secondary stack
   --  for the environment task if the secondary stack is used by the program
   --  being binded.
   --
   --  To support multithreaded ZFP-based applications, the binder supports
   --  the creation of additional secondary stacks using the -Qnnn binder
   --  switch. For the user to make use of these generated stacks, all threads
   --  need to call SS_Init with a null-object parameter to be assigned a
   --  stack. It is then the responsibility of the user to store the returned
   --  pointer in a way that can be can retrieved via the user implementation
   --  of the __gnat_get_secondary_stack function. In this scenario it is
   --  recommended to use thread local variables. For example, if the
   --  Thread_Local_Storage aspect is supported on the target:
   --
   --  pragma Warnings (Off);
   --  with System.Secondary_Stack; use System.Secondary_Stack;
   --  pragma Warnings (On);
   --
   --  package Secondary_Stack is
   --     Thread_Sec_Stack : System.Secondary_Stack.SS_Stack_Ptr := null
   --       with Thread_Local_Storage;
   --
   --     function Get_Sec_Stack return SS_Stack_Ptr
   --       with Export, Convention => C,
   --            External_Name => "__gnat_get_secondary_stack";
   --
   --    function Get_Sec_Stack return SS_Stack_Ptr is
   --    begin
   --       if Thread_Sec_Stack = null then
   --          SS_Init (Thread_Sec_Stack);
   --       end if;
   --
   --       return Thread_Sec_Stack;
   --    end Get_Sec_Stack;
   --  end Secondary_Stack;

   -----------------
   -- SS_Allocate --
   -----------------

   procedure SS_Allocate
     (Addr         : out Address;
      Storage_Size : SSE.Storage_Count;
      Alignment    : SSE.Storage_Count := Standard'Maximum_Alignment)
   is
      use Interfaces;
      use type System.Storage_Elements.Storage_Count;
      use type CHERI.Bounds_Length;

      function Align_Addr (Addr : Address) return Address with Inline;
      --  Align Addr to the next multiple of Alignment

      ----------------
      -- Align_Addr --
      ----------------

      function Align_Addr (Addr : Address) return Address is
      begin

         --  L : Alignment
         --  A : Standard'Maximum_Alignment

         --           Addr
         --      L     |     L           L
         --   ...A--A--A--A--A--A--A--A--A--A--A--...
         --                  |     |
         --      \----/      |     |
         --    Addr mod L    |   Addr + L
         --                  |
         --                Addr + L - (Addr mod L)

         return Addr + (Alignment - (Addr mod Alignment));
      end Align_Addr;

      Max_Align   : constant := Standard'Maximum_Alignment;
      Mem_Request : CHERI.Bounds_Length;
      Free_Space  : SS_Ptr;

      Over_Aligning : constant Boolean :=
        Alignment > Standard'Maximum_Alignment;

      Over_Align_Padding : SSE.Storage_Count := 0;

      Capability_Lower_Bound_Padding : CHERI.Bounds_Length;
      --  Padding needed to align the capability's lower bound.

      Adjusted_Storage_Size  : CHERI.Bounds_Length;
      --  Storage_Size plus padding for over-alignment and extra padding to
      --  align the capability's upper bound.

      Capability_Lower_Bound : Address;

      Stack : constant SS_Stack_Ptr := Get_Sec_Stack;

   begin
      --  Alignment must be a power of two and can be:

      --  - lower than or equal to Maximum_Alignment, in which case the result
      --    will be aligned on Maximum_Alignment;
      --  - higher than Maximum_Alignment, in which case the result will be
      --    dynamically realigned.

      if Over_Aligning then
         Over_Align_Padding := Alignment;
      end if;

      --  Due to capability compression, large allocations require the bounds
      --  to be aligned a power-of-2 boundary (larger bounds are more coarsely
      --  aligned) to ensure the capability is representable. This may require
      --  extra padding before and after the allocated memory:
      --
      --  T : Stack.Top
      --  L : Capability lower bound
      --  A : allocated address (Addr)
      --  S : Addr + Storage_Size
      --  U : Capability upper bound
      --
      --                                       padding for
      --                                    cap. upper bound
      --  Over_Align_Padding   Storage_Size     alignment
      --            |               |               |
      --           /--\/-------------------------\/---\
      --
      --  ...T-----L---A--------------------------S----U---...
      --
      --     \----/\----------------------------------/
      --        |                  |
      --        |         Adjusted_Storage_Size
      --        |
      --  Capability_Lower_Bound_Padding

      --  Round up Storage_Size so that the capability's upper bound will be
      --  precisely representable and will not be rounded up, which would
      --  overlap the bounds with the next allocation's memory.

      Adjusted_Storage_Size :=
        CHERI.Representable_Length
          (CHERI.Bounds_Length (Storage_Size + Over_Align_Padding));

      --  Calculate the amount of extra padding needed to align the
      --  capability's lower bound so that it will be precisely representable
      --  and will not be rounded down to overlap with the previous
      --  allocation's memory.

      Addr := Stack.Internal_Chunk'Address +
        SSE.Storage_Offset (Stack.Top - Stack.Internal_Chunk'First);

      Capability_Lower_Bound :=
        CHERI.Capability_With_Address_Aligned_Up
          (Addr, CHERI.Bounds_Length (Storage_Size + Over_Align_Padding));

      Capability_Lower_Bound_Padding :=
        CHERI.Bounds_Length
          (SSE.Storage_Offset'(Capability_Lower_Bound - Addr));

      Mem_Request := Adjusted_Storage_Size + Capability_Lower_Bound_Padding;

      --  Round up Mem_Request to the nearest multiple of the max alignment
      --  value for the target to ensure efficient access and that the next
      --  available Byte is always aligned on the default alignment value.

      --  First perform checks to ensure that the rounding operation does not
      --  overflow SS_Ptr.

      if CHERI.Bounds_Length (SS_Ptr'Last) - Standard'Maximum_Alignment <
        Mem_Request
      then
         raise Storage_Error;
      end if;

      Mem_Request := ((Mem_Request + Max_Align - 1) / Max_Align) * Max_Align;

      --  Check if max stack usage is increasing

      if CHERI.Bounds_Length (Stack.Max) - CHERI.Bounds_Length (Stack.Top)
         < Mem_Request
      then
         --  If so, check if the stack is exceeded, noting Stack.Top points to
         --  the first free byte (so the value of Stack.Top on a fully
         --  allocated stack will be Stack.Size + 1). The comparison is formed
         --  to prevent integer overflows.

         Free_Space := (Stack.Size - Stack.Top) + 1;

         if CHERI.Bounds_Length (Free_Space) < Mem_Request then
            raise Storage_Error;
         end if;

         --  Record new max usage

         Stack.Max := Stack.Top + SS_Ptr (Mem_Request);
      end if;

      --  Set resulting address and update top of stack pointer and constrain
      --  the bounds of the resulting capability.

      --  Here, there is enough memory to get the whole requested memory
      --  since the available memory was checked in the previous block.

      Addr := CHERI.Capability_With_Exact_Bounds
        (Capability_Lower_Bound, Adjusted_Storage_Size);

      if Over_Aligning then
         Addr := Align_Addr (Addr);
      end if;

      Stack.Top := Stack.Top + SS_Ptr (Mem_Request);
   end SS_Allocate;

   ----------------
   -- SS_Get_Max --
   ----------------

   function SS_Get_Max return Long_Long_Integer is
   begin
      --  Stack.Max points to the first untouched byte in the stack, thus the
      --  maximum number of bytes that have been allocated on the stack is one
      --  less the value of Stack.Max.

      return Long_Long_Integer (Get_Sec_Stack.Max - 1);
   end SS_Get_Max;

   -------------
   -- SS_Init --
   -------------

   procedure SS_Init
     (Stack : in out SS_Stack_Ptr;
      Size  : SP.Size_Type := SP.Unspecified_Size)
   is
      use Parameters;

   begin
      --  If the size of the secondary stack for a task has been specified via
      --  the Secondary_Stack_Size aspect, then the compiler has allocated the
      --  stack at compile time and the task create call will provide a pointer
      --  to this stack. Otherwise, the task will be allocated a secondary
      --  stack from the pool of default-sized secondary stacks created by the
      --  binder.

      if Stack = null then
         --  Allocate a default-sized stack for the task.

         if Size = Unspecified_Size
           and then Binder_SS_Count > 0
           and then Num_Of_Assigned_Stacks < Binder_SS_Count
         then
            --  The default-sized secondary stack pool is passed from the
            --  binder to this package as an Address since it is not possible
            --  to have a pointer to an array of unconstrained objects. A
            --  pointer to the pool is obtainable via an unchecked conversion
            --  to a constrained array of SS_Stacks that mirrors the one used
            --  by the binder.

            --  However, Ada understandably does not allow a local pointer to
            --  a stack in the pool to be stored in a pointer outside of this
            --  scope. While the conversion is safe in this case, since a view
            --  of a global object is being used, using Unchecked_Access
            --  would prevent users from specifying the restriction
            --  No_Unchecked_Access whenever the secondary stack is used. As
            --  a workaround, the local stack pointer is converted to a global
            --  pointer via System.Address.

            declare
               type Stk_Pool_Array is array (1 .. Binder_SS_Count) of
                 aliased SS_Stack (Default_SS_Size);
               type Stk_Pool_Access is access Stk_Pool_Array;

               function To_Stack_Pool is new
                 Ada.Unchecked_Conversion (Address, Stk_Pool_Access);

               pragma Warnings (Off);
               function To_Global_Ptr is new
                 Ada.Unchecked_Conversion (Address, SS_Stack_Ptr);
               pragma Warnings (On);
               --  Suppress aliasing warning since the pointer we return will
               --  be the only access to the stack.

               Local_Stk_Address : System.Address;

            begin
               Num_Of_Assigned_Stacks := Num_Of_Assigned_Stacks + 1;

               pragma Assert (Num_Of_Assigned_Stacks >= 1);
               --  Num_Of_Assigned_Stacks is defined as Natural. So after, the
               --  Previous increment it shall be greater or equal to 1.

               Local_Stk_Address :=
                 To_Stack_Pool
                   (Default_Sized_SS_Pool) (Num_Of_Assigned_Stacks)'Address;
               pragma Annotate (CodePeer, False_Positive, "array index check",
                                "Num_Of_Assigned_Stacks < Binder_SS_Count.");
               Stack := To_Global_Ptr (Local_Stk_Address);
            end;

         --  Many run-times unconditionally bring in this package and call
         --  SS_Init even though the secondary stack is not used by the
         --  program. In this case return without assigning a stack as it will
         --  never be used.

         elsif Binder_SS_Count = 0 then
            return;

         else
            raise Program_Error;
         end if;
      end if;

      Stack.Top := 1;
      Stack.Max := 1;
   end SS_Init;

   -------------
   -- SS_Mark --
   -------------

   function SS_Mark return Mark_Id is
   begin
      return Mark_Id (Get_Sec_Stack.Top);
   end SS_Mark;

   ----------------
   -- SS_Release --
   ----------------

   procedure SS_Release (M : Mark_Id) is
   begin
      Get_Sec_Stack.Top := SS_Ptr (M);
   end SS_Release;

end System.Secondary_Stack;