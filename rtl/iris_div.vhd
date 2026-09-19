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
-- 54-bit SRT divider
-- Generates a result value of 1.0 - 3.99. Op1 (divident) can be subnormal,
-- extra cycles are added to generate a normalized operand. In this case,
-- decexp output is set to decrement exponent the required number of times.
-- Computation time: 11 - 27 clocks for single, 18 - 56 for double
--
-- 54-bit non-restoring sqrt
-- Computation time: 27 clocks for single, 56 for double
-- Returns values of 1.0 - 1.99 ...
-----------------------------------------------------------------------------
-- Entity: 	iris_div
-- Author:	Jiri Gaisler
-- Version: 1.0
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity iris_div is
  generic( -- div speed. 2 is a good compromise, 3 fastest with poorer timinng
    srtopt : integer range 0 to 3 := 3 
  );
 port ( 
   clk :     in std_logic;
   rst :     in std_logic;
   op1 : in std_logic_vector(56 downto 0);
   op2 : in std_logic_vector(56 downto 0);
   divstart :   in std_logic;
   sqrtstart :   in std_logic;
   sp    : in std_logic;      -- single precision
   exp0  : in std_logic;      -- lsb exponent
   result :  out std_logic_vector(56 downto 1);
   decexp : out std_logic;
   busy : out std_logic);
end;

architecture rtl of iris_div is
  constant mbits: integer := 52;
	constant ebits: integer := 11;
  constant zero64 : std_logic_vector(127 downto 0) :=  (others => '0');
  constant ones64 : std_logic_vector(127 downto 0) :=  (others => '1');
  constant n : integer := mbits + 3;
  constant e : integer := ebits;
  type state_type is (idle, sqrtfirst, sqrtcalc, denorm, divcalc, 
    divlast, final);

  type reg_type is record
    divisor : std_logic_vector(n-1 downto 0);
    q : std_logic_vector(2*n - 1 downto 0);
    qn : std_logic_vector(n - 1 downto 0);
    start : std_logic;
    state : state_type;
    start2 : std_logic;
    den, sticky, add, div, skip : std_logic;
    cin : unsigned(0 downto 0);
    a1in, a2in : std_logic_vector(1 downto 0);
  end record;

  signal r, rin : reg_type;

begin

  comb : process(r, divstart, sqrtstart, op1, op2, rst, sp, exp0)
  variable v : reg_type;
  variable diff : std_logic_vector(n-1 downto 0);
  variable sticky : std_logic;
  variable dividend, divisor : std_logic_vector(n-1 downto 0);
  variable addin1, addin2 : unsigned(n+1 downto 0);
  variable addout : std_logic_vector(n+1 downto 0);
  variable qs : std_logic_vector(2 downto 0);
  begin

    v := r;

    dividend := op1(56 downto 2);
    divisor :=  op2(56 downto 2);

    if r.q(n*2-1 downto n+1) /= zero64(n*2-1 downto n+1) then
      sticky := '1';
    else
      sticky := '0';
    end if;

    addin1 := unsigned(r.q(n*2-1 downto n) & r.a1in);
    addin2 := unsigned(r.divisor & r.a2in);

    if r.add = '1' then
      addout := std_logic_vector(addin1 + addin2 + r.cin);
    else
      addout := std_logic_vector(addin1 - addin2 - r.cin);
    end if;

    diff := addout(n+1 downto 2);
    qs := diff(54 downto 52);
    v.skip := '0';

    case r.state is
    when idle =>
      v.divisor := divisor;
      v.start := divstart;
      v.den := '0'; v.div := '0'; v.add := '0'; v.cin := "0";
      v.a1in := "00";
      v.a2in := "00";
      v.qn := (others => '0');
      if divstart = '1' then
        v.start := '1'; v.add := '0'; v.div := '1';
        v.q := dividend & zero64(n-1 downto 1) & '1';
        v.sticky := '0';
        v.add := v.q(n*2-1);
        if op1(55) = '0' then
          v.state := denorm; v.q(0) := '0';
        else
          v.state := divcalc;
        end if;
      elsif sqrtstart = '1' then
        v.start := '1';
        v.add := '0';
        v.state := sqrtfirst;
        v.sticky := '0';
        v.q := zero64(n-1 downto 0) & divisor;
        v.divisor := (others => '0');
      end if;
    when sqrtfirst =>
    -- if exponent is even, shift op one bit left and decrement exponent
        if exp0 = '0' then
          v.q(n-1 downto 0) := r.q(n-2 downto 0) & '0';
          v.den := '1';
        end if;
        v.state := sqrtcalc;
        v.a1in := v.q(n-1 downto n-2);
        v.a2in := v.add & '1';
    when sqrtcalc =>
      v.den := '0';
      v.divisor := r.divisor(n-2 downto 0) & not diff(n-1);
      v.q(n-1 downto 0) := r.q(n-3 downto 0) & "00";
      v.q(n*2-1 downto n) := addout(n-1 downto 0);
      v.add := addout(n+1);
      v.a1in := v.q(n-1 downto n-2);
      v.a2in := v.add & '1';
      if sp = '0' then -- double precision
        if (r.divisor(52) = '1') then 
          v.state := final; v.start := '0';
          v.q(n-1 downto 0) := v.divisor;
        end if;
      else
        if (r.divisor(24) = '1') then 
          v.state := final; v.start := '0';
          v.q(n-1 downto 0) := v.divisor;
        end if;
      end if;
    when denorm =>
      v.q := r.q(n*2-2 downto 0) & '0';
      v.den := '1';
      if r.q(107) = '1' then
        v.state := divcalc;
        v.add := v.q(n*2-1);
        v.q(0) := '1';
      end if;
    when divcalc =>
      v.den := '0';
      v.q := diff(n-2 downto 1) & r.q(n downto 0) & '0';
      qs := r.q(n*2-1 downto n*2-3);
      case qs  is
      when "000" | "111" =>
        v.q := r.q(n*2-2 downto 0) & '0';
        v.qn := r.qn(n-2 downto 0) & '0';
      when "001" | "110" =>
        v.q := r.q(n*2-2 downto 0) & '0';
        v.qn := r.qn(n-2 downto 0) & '0';
      when "010" | "011" =>
        v.q(0) := '1';
        v.qn := r.qn(n-2 downto 0) & '0';
        v.add := '0';
      when others =>
        v.q(0) := '0';
        v.qn := r.qn(n-2 downto 0) & '1';
        v.add := '1';
      end case;
      -- skip forward up to 4 steps if quotient selector is zero
      if (((r.q(53 downto 51) = "000") and (sp = '0')) or 
          ((r.q(25 downto 23) = "000") and (sp = '1'))) and 
       ((v.q(n*2-1 downto n*2-4) = "0000") or 
       (v.q(n*2-1 downto n*2-4) = "1111")) and (r.den = '0') and (srtopt > 2)
      then 
        v.q := v.q(n*2-4 downto 0) & "000";
        v.qn := v.qn(n-4 downto 0) & "000";
        v.skip := '1';
      elsif (((r.q(53 downto 52) = "00") and (sp = '0')) or
          ((r.q(25 downto 24) = "00") and (sp = '1'))) and 
       ((v.q(n*2-1 downto n*2-3) = "000") or 
       (v.q(n*2-1 downto n*2-3) = "111")) and (r.den = '0') and (srtopt > 1)
      then
        v.q := v.q(n*2-3 downto 0) & "00";
        v.qn := v.qn(n-3 downto 0) & "00";
        v.skip := '1';
      elsif (((r.q(53) = '0') and (sp = '0')) or
          ((r.q(25) = '0') and (sp = '1'))) and 
       ((v.q(n*2-1 downto n*2-2) = "00") or 
       (v.q(n*2-1 downto n*2-2) = "11")) and (r.den = '0') and (srtopt > 0)
      then
        v.q := v.q(n*2-2 downto 0) & "0";
        v.qn := v.qn(n-2 downto 0) & "0";
        v.skip := '1';
      end if;
      if sp = '0' then -- double precision
        if  (r.q(54) = '1') then 
          v.state := divlast;
        end if;
      else
        if  (r.q(26) = '1') then 
          v.state := divlast;
        end if;
      end if;
      v.add := v.q(n*2-1);
      if v.state = divlast then
        v.cin(0) := v.add; -- on exit, decrement result if remainder negative
        v.q := v.q(n-1 downto 0) & v.q(n*2-1 downto n);
        v.divisor := v.qn; v.add := '0';
        v.sticky := sticky;
      end if;
    when divlast =>
      v.q(n-1 downto 0) := diff(n-1 downto 0); -- calculate final quotient
      v.start := '0';
      v.state := final;
    when final =>
      if r.div = '0' then
        if sp = '1' then
          if r.q(13 downto 0) /= zero64(13 downto 0) then
            v.sticky := '1';
          else
            v.sticky := r.q(26+55);
          end if;
        else
          if r.q(26 downto 0) /= zero64(26 downto 0) then
            v.sticky := '1';
          else
            v.sticky := r.q(n*2-1);
          end if;
        end if;
      end if;
      v.state := idle;
    end case;

    v.start2 := r.start;

    if rst = '1' then
      v.start := '0'; v.start2 := '0';
      v.state := idle; v.den := '0'; v.div := '0';
    end if;
    rin <= v;
  end process;

  result <= r.q(54 downto 0) & rin.sticky when sp = '0' else
        r.q(26 downto 0) & rin.sticky & X"0000000";
  busy <= r.start;
  decexp <= r.den;

  reg : process(clk)
  begin
    if rising_edge( clk) then
      r <= rin;
    end if;
  end process;

end rtl;


