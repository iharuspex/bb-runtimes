------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--               S Y S T E M . V A L _ D E C I M A L _ 1 2 8                --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--            Copyright (C) 2020, Free Software Foundation, Inc.            --
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

--  This package contains routines for scanning values for decimal fixed point
--  types up to 128-bit mantissa, for use in Text_IO.Decimal_IO, and the Value
--  attribute for such decimal types.

with Interfaces;
with System.Arith_128;
with System.Value_D;

package System.Val_Decimal_128 is
   pragma Preelaborate;

   subtype Int128 is Interfaces.Integer_128;
   subtype Uns128 is Interfaces.Unsigned_128;

   package Impl is new Value_D (Int128, Uns128, Arith_128.Scaled_Divide128);

   function Scan_Decimal128
     (Str   : String;
      Ptr   : not null access Integer;
      Max   : Integer;
      Scale : Integer) return Int128
     renames Impl.Scan_Decimal;

   function Value_Decimal128
     (Str   : String;
      Scale : Integer) return Int128
    renames Impl.Value_Decimal;

end System.Val_Decimal_128;
