----------------------------------------------------------------------------
--  This file is a part of the IRIS FPU VHDL model
--  Copyright (C) 2025 Jiri Gaisler
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; version 2.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-----------------------------------------------------------------------------
-- Multiplier unit. Performs a 54x54 multiply using 3x 18x18 mul blocks
-- DP mul takes 5 clocks, SP 4 clock. If op2 contains 18 or 36 trailing zeros,
-- one or two cycles are removed.
------------------------------------------------------------------------------
-- Entity: 	iris_mul
-- Author:	Jiri Gaisler
-- Version: 1.0
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity iris_mul is
  generic(
    mbits: integer := 52;
	  ebits: integer := 11;
    oreg : integer := 0
  );
 port ( 
   clk :     in std_logic;
   rst :     in std_logic;
   op1 : in std_logic_vector(56 downto 0);
   op2 : in std_logic_vector(56 downto 0);
   start :   in std_logic;
   sp    : in std_logic;      -- single precision
   result :  out std_logic_vector(56 downto 0);
   busy : out std_logic);
end;

architecture rtl of iris_mul is
  constant zero64 : unsigned(127 downto 0) :=  (others => '0');
  constant ones64 : unsigned(127 downto 0) :=  (others => '1');
  type state_type is (idle, compute);

  type reg_type is record
    op1, op2 : unsigned(53 downto 0);
    pres1, pres2, pres3 : unsigned(35 downto 0);
    sum1, sum2 : unsigned(71 downto 0);
    count  : natural range 0 to 7;
    start : std_logic;
    state : state_type;
    sticky : std_logic;
    busy, busy2 : std_logic;
    quick : std_logic;
  end record;

  signal r, rin : reg_type;

begin

  c : process(r, start, op1, op2, rst, sp)
  variable v : reg_type;
  variable sticky : std_logic;
  variable sum2 : unsigned(72 downto 0);
  variable p : unsigned(113 downto 0);
  begin

    v := r;
    v.start := start;
    v.pres1 := r.op1(17 downto 0) * r.op2(17 downto 0);
    v.pres2 := r.op1(35 downto 18) * r.op2(17 downto 0);
    v.pres3 := r.op1(53 downto 36) * r.op2(17 downto 0);
    v.sum1 := ((r.pres3 & r.pres1(35 downto 18)) +
        (zero64(17 downto 0) & r.pres2)) &
          r.pres1(17 downto 0);
    sum2 := (zero64(18 downto 0) & r.sum2(71 downto 18)) + r.sum1;

    case r.state is
    when idle =>
      v.count := 0; v.quick := '0'; v.sticky := '0'; v.busy := '0';
      v.op1 := unsigned(op1(56 downto 3));
      v.op2 := unsigned(op2(56 downto 3));
      if start = '1' then
        v.state := compute;
        v.sum2 := (others => '0');
        v.busy := '1'; v.count := r.count; v.busy2 := '1';
        v.op2 := zero64(17 downto 0) & r.op2(53 downto 18);
      elsif (unsigned(op2(38 downto 3)) = zero64(38 downto 3)) then
        v.op2 := zero64(35 downto 0) & unsigned(op2(56 downto 39));
        v.count := 2; v.quick := '1';
      elsif (unsigned(op2(20 downto 3)) = zero64(17 downto 0)) then
        v.op2 := zero64(17 downto 0) & unsigned(op2(56 downto 21));
        v.count := 1;
      end if;
    when compute =>
      if r.start = '0' then
        v.sum2 := sum2(71 downto 0);
      end if;
      v.op2 := zero64(17 downto 0) & r.op2(53 downto 18);
      if r.count /= 4 then
        if r.sum2(17 downto 0) /= zero64(17 downto 0) then
          v.sticky := '1';
        end if;
      end if;
      v.count := r.count + 1;
      if r.count = 2 then
        v.busy2 := '0';
      end if;
      if r.count = 3 then
        if sp = '1' then
          if v.sum2(42 downto 0) /= zero64(42 downto 0) then
            v.sticky := '1';
          end if;
        else
          if v.sum2(14 downto 0) /= zero64(14 downto 0) then
            v.sticky := '1';
          end if;
        end if;
        v.state := idle;
        v.busy := '0';
      end if;
      if (r.quick and not r.start) = '1' then
        v.sum2 := v.sum1;
        v.state := idle;
        v.busy := '0';
      end if;
    end case;

    if rst = '1' then
      v.start := '0'; v.state := idle; v.count := 0;
      v.busy := '0'; v.busy2 := '0';
    end if;
    rin <= v;
  end process;

  result <= 
    std_logic_vector(rin.sum2(69 downto 43)) & rin.sticky  & '0' & X"0000000"
      when sp = '1' else
        std_logic_vector(rin.sum2(69 downto 15)) & rin.sticky  & '0'
      when r.quick = '0' else std_logic_vector(r.sum1(69 downto 13));
  busy <= r.busy2 when oreg = 0 else r.busy;

  reg : process(clk)
  begin
    if rising_edge( clk) then
      r <= rin;
    end if;
  end process;

end rtl;
