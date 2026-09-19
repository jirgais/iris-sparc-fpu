----------------------------------------------------------------------------
--  This file is a part of the IRIS FPU VHDL model
--  Copyright (C) 2026, Jiri Gaisler
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
-- IRIS floating-point unit, main module
-- IEEE-754-2008 singel/double precision add/sub/cmp/conv/mul/div/sqrt unit.
-- Full support for denormalized numbers and all four rounding modes.
-- 5 clocks latency for most add/sub/conv operations, 8 clks for special cases.
-- 7 - 9 clocks latency for mul, 17 - 66 for div/sqrt
-- Approximately 3,800 LUT (Xilinx Spartan6), 3 DSP blocks, 100 MHz clock
-- Entity: 	irisfpu
-- Author:	Jiri Gaisler
-- Version: 1.0
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity irisfpu is
  generic(
    fpga      : integer := 0;  -- optimize timing for fpga
    busydelay : integer := 0;  -- 0/1 clock delay from busy to data (meiko=1)
    srtopt    : integer range 0 to 3 := 3;  -- div speed, increases area
    tinypostrnd : integer range 0 to 1 := 0;  -- detect tininess after rounding
    fsmulden  : integer range 0 to 1 := 1  -- enable FSMULD instruction
  );
  port(
    clock      : in  std_logic;
    FpInst     : in  std_logic_vector(9 downto 0); --op3(0) & opf
    FpOp       : in  std_logic;
    FpLd       : in  std_logic;
    Reset      : in  std_logic;
    fprf_dout1 : in  std_logic_vector(63 downto 0);
    fprf_dout2 : in  std_logic_vector(63 downto 0);
    RoundingMode : in  std_logic_vector(1 downto 0); -- 00:near, 01: zero, 10:+inf, 11:-inf
    FpBusy     : out std_logic;
    FracResult : out std_logic_vector(54 downto 3);
    ExpResult  : out std_logic_vector(10 downto 0);
    SignResult : out std_logic;
    SNnotDB    : out std_logic; -- 0: double result, 1: single result
    Excep      : out std_logic_vector(5 downto 0); -- unimp, nv, ovf, unf, divz, nx
    ConditionCodes : out std_logic_vector(1 downto 0)-- 00:op1=op2, 01:op1<op2, 10:op1>op2, 11:unordered
  );
end;

architecture rtl of irisfpu is

  constant zeros : std_logic_vector(63 downto 0) := (others => '0');
  constant ones : std_logic_vector(63 downto 0) := (others => '1');

  function enc( d : std_logic_vector(1 downto 0)) return std_logic_vector is
  begin
    case d is
      when "00" => return "10";
      when "01" => return "01";
      when "10" => return "00";
      when others => return "00";
    end case;
  end function enc;

  function clzi(
    n : in natural;
    i : in std_logic_vector) return std_logic_vector is
    variable v : std_logic_vector(i'length-1 downto 0):=i;  
  begin
    v := i;
    if v(n-1+n)='0' then
      return (v(n-1+n) and v(n-1)) & '0' & v(2*n-2 downto n);
    else
      return (v(n-1+n) and v(n-1)) & not v(n-1) & v(n-2 downto 0);
    end if;
  end function clzi;

  function clz64 ( v : std_logic_vector(0 to 63)) return std_logic_vector is
    variable e : std_logic_vector(0 to 63);     -- 64
    variable a : std_logic_vector(0 to 16*3-1); -- 48
    variable b : std_logic_vector(0 to 8*4-1);  -- 32
    variable c : std_logic_vector(0 to 4*5-1);  -- 20
    variable d : std_logic_vector(0 to 2*6-1);  -- 12
  begin
    for i in 0 to 31 loop e(i*2 to i*2+1):= enc(v(i*2 to i*2+1)); end loop;
    for i in 0 to 15 loop a(i*3 to i*3+2):= clzi(2, e(i*4 to i*4+3)); end loop;
    for i in 0 to 7  loop b(i*4 to i*4+3):= clzi(3, a(i*6 to i*6+5)); end loop;
    for i in 0 to 3  loop c(i*5 to i*5+4):= clzi(4, b(i*8 to i*8+7)); end loop;
    for i in 0 to 1  loop d(i*6 to i*6+5):= clzi(5, c(i*10 to i*10+9)); end loop;
    return clzi(6, d(0 to 11));
  end function clz64;

  -- calculate inc for different rounding modes
  function rbit(rm : std_logic_vector(1 downto 0);     -- rounding mode
                man : std_logic_vector(3 downto 0);   -- lsb/guard/round/sticky
                sign, sticky : std_logic)
                return std_logic_vector is
    variable grs, near : std_logic;
    variable man32 : std_logic_vector(1 downto 0);
  begin
    grs := man(2) or man(1) or man(0) or sticky;
    near := (man(2) and (man(3) or man(1) or man(0) or sticky));
    case rm is
    when "00" =>         -- round to nereast
      man32 := '0' & near;
    when "10" =>         -- round +inf
      man32 := (grs and not sign) & '0';
    when "11" =>         -- round -inf
      man32 := (grs and sign) & '0';
    when others =>      -- round to zero
      man32 := '0' & '0';
    end case;
    return(man32);
  end;

  function rbit2(rm : std_logic_vector(1 downto 0);     -- rounding mode
                man : std_logic_vector(4 downto 0);   -- lsb/guard/round/sticky
                sign, sticky, man56 : std_logic)
                return std_logic_vector is
    variable grs, near : std_logic;
    variable man32 : std_logic_vector(1 downto 0);
  begin
    if man56 = '1' then
      grs := man(3) or man(2) or man(1) or man(0) or sticky;
      near := (man(3) and (man(4) or man(2) or man(1) or man(0) or sticky));
    else
      grs := man(2) or man(1) or man(0) or sticky;
      near := (man(2) and (man(3) or man(1) or man(0) or sticky));
    end if;
    case rm is
    when "00" =>         -- round to nereast
      man32 := '0' & near;
    when "10" =>         -- round +inf
      man32 := (grs and not sign) & '0';
    when "11" =>         -- round -inf
      man32 := (grs and sign) & '0';
    when others =>      -- round to zero
      man32 := '0' & '0';
    end case;
    if man56 = '1' then return(man32 & '0');
    else return('0' & man32); end if;
  end;

  type state_type is (idle, align, compute, normalize1,
                      normalize2, roundm, rounde, rounds, denorm);
  type mux2type is (man2, rights, adder, lefts, addrs1, right1, divd, muld);

  type reg_type is record
    sign, nv, ovf, unf, dz, nx, unimp, swap, fdsden : std_logic;
    fpop : std_logic;
    fpld, busy, sp : std_logic;
    st : state_type;
    fpinst : std_logic_vector(9 downto 0);
    rm  : std_logic_vector(1 downto 0);    
    esub, msub, sub, den : std_logic;
    sign1 : std_logic;
    exp1 : std_logic_vector(12 downto 0);
    man1 : std_logic_vector(56 downto 0);
    sign2 : std_logic;
    exp2 : std_logic_vector(12 downto 0);
    man2 : std_logic_vector(56 downto 0);
    expdiff  : unsigned(11 downto 11);    
    shcnt  : unsigned(5 downto 0);    
    lzcnt  : std_logic_vector(5 downto 0);    
    nan  : std_logic_vector(1 downto 0);    
    msel1 : std_logic_vector(1 downto 0);    
    msel2  : mux2type; --std_logic_vector(2 downto 0);    
    ezero1, ezero2 : std_logic;
    mzero1, mzero2 : std_logic;
    inf1, inf2 : std_logic;
    nan1, nan2 : std_logic;
    snan1, snan2 : std_logic;
    zero1, zero2 : std_logic;
    faddd, cmp, fitod, fitos, fstoi, fdtoi, fstoiovf : std_logic;
    fdtos, fstod, fdivd, fsqrtd, dx, divstart : std_logic;
    muldiv, fmuld, mulstart, fmov : std_logic;
  end record;

  signal mulres : std_logic_vector(56 downto 0);
  signal mulstart, mulbusy : std_logic;
  signal divres : std_logic_vector(56 downto 1);
  signal divstart, sqrtstart, divbusy, divdecex, divrst : std_logic;
  signal r, rin : reg_type;
  signal mdop1, mdop2 : std_logic_vector(56 downto 0);
  signal mulsp : std_logic;

begin

  mulsp <= r.sp and not r.fpinst(5) when fsmulden = 1 else r.sp;

  mul : entity work.iris_mul
  port map (Clock, divrst, mdop1, mdop2, mulstart, mulsp, mulres, mulbusy);

  div : entity work.iris_div
    generic map (srtopt)
    port map (Clock, divrst, mdop1, mdop2, divstart, sqrtstart, r.sp, r.exp1(0),
        divres, divdecex, divbusy);

  comb : process (r, fprf_dout1, fprf_dout2, fpld, fpop, FpInst, Reset,
    RoundingMode, divres, divdecex, divbusy, mulres, mulbusy)
  variable v : reg_type;
  variable norm_lzcnt : std_logic_vector(6 downto 0);
  variable rnd_exp2, rnd_expres : std_logic_vector(12 downto 0);
  variable expres : std_logic_vector(10 downto 0);
  variable l_shift_out : std_logic_vector(63 downto 0);
  variable r_shift_out : std_logic_vector(119 downto 0);
  variable cman : std_logic_vector(56 downto 0);
  variable comp_neg, maddout, l_shift : std_logic_vector(56 downto 0);
  variable lsb, rnd, swap, norm_negate : std_logic;
  variable r_shift_sticky : std_logic;
  variable r_shift_sticky_s : std_logic;
  variable r_shift_sticky_d : std_logic;
  variable ezero1, ezero2 : std_logic;
  variable inf1, inf2 : std_logic;
  variable mzero, mzero1, mzero2, sign2 : std_logic;
  variable expdiff1, expdiff2 : unsigned(11 downto 0);
  variable cexp : std_logic_vector(10 downto 0);
  variable stsp : std_logic_vector(31 downto 0);
  variable stdp : std_logic_vector(63 downto 0);
  variable aexc : std_logic_vector(5 downto 0);
  variable fcc : std_logic_vector(1 downto 0);
  variable faddd, fitos, fitod, fstoi, fdtoi, mzerofstoi : std_logic;
  variable fdtos, fstod, fmov, unimp : std_logic;
  variable fdivd, fsqrtd, vdivstart, vdivrst, vsqrtstart : std_logic;
  variable fmuld, vmulstart : std_logic;
  variable vmdop1, vmdop2 : std_logic_vector(56 downto 0);

  begin
    v := r;

    swap := '0'; rnd_exp2 := r.exp2;
    ezero1 := '0'; ezero2 := '0'; 
    inf1 := '0'; inf2 := '0'; 
    mzero1 := '0'; mzero2 := '0';
    v.msel1 := "00"; v.msel2 := man2; faddd := '0';
    fitos := '0'; fitod := '0';
    fstoi := '0'; fdtoi := '0';
    fstod := '0'; fdtos := '0'; fmov := '0'; unimp := '0';
    fdivd := '0'; vdivstart := '0'; vdivrst := '0';
    fsqrtd := '0'; vsqrtstart := '0';
    fmuld := '0'; vmulstart := '0';

    case r.fpinst(8 downto 1) is
    when X"14" | X"15" => fsqrtd := '1';
    when X"20" | X"21" | X"22" | X"23" => faddd := '1';
    when X"24" | X"25" => fmuld := '1';
    when X"34" => 
      if fsmulden = 1 then fmuld := '1';
      else unimp := '1'; end if;
    when X"26" | X"27" => fdivd := '1';
    when X"62" => fitos := '1'; fitod := '1';
    when X"63" => fdtos := '1'; fstod := '1';
    when X"64" => fstod := r.fpinst(0); fitod := not r.fpinst(0);
    when X"68" => fstoi := '1';
    when X"69" => fdtoi := '1'; fstoi := '1';
    when others => unimp := '1';
    end case;

-- Decode zero, inf and Nan from input operands
    if (r.exp1(7 downto 0) = zeros(7 downto 0)) and
      ((r.sp = '1') or (r.exp1(10 downto 8) = "000"))
    then ezero1 := '1'; end if;
    if (r.exp2(7 downto 0) = zeros(7 downto 0)) and
      ((r.sp = '1') or (r.exp2(10 downto 8) = "000"))
    then ezero2 := '1'; end if;
    if (r.exp1(7 downto 0) = ones(7 downto 0)) and
      ((r.sp = '1') or (r.exp1(10 downto 8) = "111"))
    then inf1 := '1'; end if;
    if (r.exp2(7 downto 0) = ones(7 downto 0)) and
      ((r.sp = '1') or (r.exp2(10 downto 8) = "111"))
    then inf2 := '1'; end if;
    if (r.man1(54 downto 32) = zeros(54 downto 32)) and
      ((r.sp = '1') or (r.man1(31 downto 3) = zeros(31 downto 3)))
    then mzero1 := '1'; end if;
    if (r.man2(54 downto 32) = zeros(54 downto 32)) and
      ((r.sp = '1') or (r.man2(31 downto 3) = zeros(31 downto 3)))
    then mzero2 := '1'; end if;
    mzero := r.mzero2 and not (r.man2(55) or r.man2(56));
    if (r.man2(56 downto 35) = zeros(56 downto 35)) then
      mzerofstoi := '1';
    else
      mzerofstoi := '0';
    end if;

    v.fpop := '0'; v.fmov := '0';
    if fpop = '1' then
      v.fpinst := fpinst;
      if fpinst(8 downto 4) /= "00000" then -- no busy on fmov/neg/abs
        v.fpop := '1';
      else
        v.fmov := '1';
      end if;
    end if;

-- Store and decode operands when FpLD = 1

    if fpld = '1' then
      v.rm := RoundingMode;
      if r.fpinst(1) = '1' then -- double operand
        v.man1 := "01" & fprf_dout1(51 downto 0) & "000";
        v.exp1 := "00" & fprf_dout1(62 downto 52);
        v.man2 := "01" & fprf_dout2(51 downto 0) & "000";
        v.exp2 := "00" & fprf_dout2(62 downto 52);
      elsif r.fpinst(0) = '1' then
        v.man1 := "01" & fprf_dout1(54 downto 32) & X"00000000";
        v.exp1 := "00000" & fprf_dout1(62 downto 55);
        v.man2 := "01" & fprf_dout2(54 downto 32) & X"00000000";
        v.exp2 := "00000" & fprf_dout2(62 downto 55);
      else -- fitos/d
        v.man1 := (others => '0');
        v.exp1 := (others => '0');
        v.man2 := 
          fprf_dout2(63) & fprf_dout2(63 downto 32) & X"000000";
        v.exp2 := (others => '0');
      end if;
      v.sign1 := fprf_dout1(63);
      v.sign2 := fprf_dout2(63);
      if r.fpinst(7 downto 2) = "010001" then -- fsub
        v.sign2 := not v.sign2;
      end if;
      if r.fpinst(9 downto 3) = "0000101" then -- fsqrt
        v.exp1 := (others => '0');
        v.man1 := (others => '0');
        v.sign1 := '0';
      end if;
      if r.fpinst(9 downto 4) = "100101" then -- fcmp
        v.sign2 := not v.sign2; v.cmp := '1'; unimp := '0';
      else v.cmp := '0'; end if;
      if r.fpinst(7 downto 4) = "1101" then -- fstoi/fdtoi
        v.man1 := (others => '0');
        v.sign1 := '0';
        if r.fpinst(0) = '1' then v.exp1 := '0' & X"0B3";
        else v.exp1 := '0' & X"433"; end if;
      end if;
      if (r.fpinst(7 downto 4) = "1100") -- fstod/fdtos
        and  (r.fpinst(1 downto 0) /= "00") then -- and not fitod/fitos
        v.man1 := (others => '0');
        v.sign1 := '0';
        if r.fpinst(0) = '1' then v.exp1 := '0' & X"380";
        else v.exp1 := '0' & X"380"; end if;
      end if;
      if r.fmov = '1' then
        fmov := '1'; 
        if (r.fpinst(1 downto 0) /= "01") or (r.fpinst(3 downto 2) = "11") 
        then unimp := '1'; else unimp := '0'; end if;
        v.sign := fprf_dout2(63);
        v.exp1 := "00000" & fprf_dout2(62 downto 55);
        if r.fpinst(2) = '1' then  -- fneg
          v.sign := not fprf_dout2(63);
        elsif r.fpinst(3) = '1' then -- fabs
          v.sign := '0';
        end if;
      end if;
      v.fitod := fitod; v.fitos := fitos;
      v.fstoi := fstoi; v.fdtoi := fdtoi;
      v.fstod := fstod; v.fdtos := fdtos;
      v.faddd := faddd; v.fdivd := fdivd;
      v.fsqrtd := fsqrtd; v.fmuld := fmuld;
      v.unimp := unimp;
      v.muldiv := fmuld or fdivd or fsqrtd;
      if fitod = '1' then v.sign1 := '0'; end if;
      v.sub := v.sign1 xor v.sign2;
      v.msub := v.sub;
      v.esub := v.sub;
      v.sp := r.fpinst(0);
--      v.fmov := fmov or unimp;
      v.busy := not (fmov or unimp);
    end if;

-- Detect zero, inf and NaN on operands
    if r.fpld = '1' then
      -- no inf/nan during fmov/fneg/fabs
      v.inf1 := inf1 and mzero1;
      v.inf2 := inf2 and mzero2;
      v.nan1 := inf1 and not mzero1;
      v.nan2 := inf2 and not mzero2;
      v.snan1 := inf1 and not mzero1 and not r.man1(54);
      v.snan2 := inf2 and not mzero2 and not r.man2(54);
      v.ezero1 := ezero1; v.ezero2 := ezero2;
      v.zero1 := ezero1 and mzero1;
      v.zero2 := ezero2 and mzero2;
      v.mzero1 := mzero1;
      v.mzero2 := mzero2;
      v.sp := v.sp or v.fdtos;
    end if;

-- Exponent subtraction 1
    expdiff1 := unsigned(r.exp1(11 downto 0)) - unsigned(r.exp2(11 downto 0));
    expdiff2 := expdiff1;
    v.shcnt := expdiff1(5 downto 0);
    swap := expdiff1(11);

-- Re-align sub-normals

    if (r.st = idle) and (ezero1 and not r.fitod) = '1' then
      vmdop1 := '0' & r.man1(54 downto 3) & "0000";
    else
      vmdop1 := r.man1;
    end if;

    if (r.st = idle) and (ezero2 and not r.fitod and not r.fmov) = '1' then
      vmdop2 := '0' & r.man2(54 downto 3) & "0000";
    else
      vmdop2 := r.man2;
    end if;

    mdop1 <= vmdop1;   -- aligned operands to mul/div units
    mdop2 <= r.man2;

    -- dont swap operands during certain operations
    if (r.cmp or r.fitod or r.fstoi or r.fdivd or r.fsqrtd or r.fmov or
        (r.fmuld and not ezero1))  = '1'
    then
      swap := '0';
    end if;

-- add/sub/cmp state machine 1
    case r.st is
    when idle =>
      if r.fpld = '1' then
	      v.st := align; v.esub := r.sub;
        if r.fstoi = '1' then
          v.sp := '0';
        end if;
        if (r.fstod or r.fdtos or r.muldiv) = '1' then
          v.sub := '0';
          v.msub := v.sub;
          v.esub := r.fdtos or r.fdivd or (v.ezero2 and r.fsqrtd);
        end if;
      end if; 
    when align =>
      v.den := '0'; v.st := compute;
      if ((r.muldiv and not r.mulstart) 
        and ((r.swap and r.ezero1) or r.ezero2)) = '1'
      then
        rnd_exp2 := zeros(12 downto 6) & r.lzcnt;
        v.esub := '0';
      elsif (r.muldiv and r.mulstart) = '1' then
        if ((r.fmuld and r.fpinst(5)) = '1') and (fsmulden = 1) then
          v.sp := '0';
        end if;
        if r.sp = '1' then 
          rnd_exp2 := "000000" & ones(6 downto 1) & (r.mulstart and r.fmuld); 
          if r.fsqrtd = '1' then rnd_exp2 := '0' & X"07F"; end if;
        else
          if ((r.fmuld and r.fpinst(5)) = '1') and (fsmulden = 1) then
            rnd_exp2 := "11100" & ones(7 downto 1) & (r.mulstart and r.fmuld);
          else
            rnd_exp2 := "000" & ones(9 downto 1) & (r.mulstart and r.fmuld);
          end if;
          if r.fsqrtd = '1' then rnd_exp2 := '0' & X"3FF"; end if;
        end if;
        v.esub := r.fmuld;
        if divdecex = '1' then
          rnd_exp2 := (others => '1');  -- decrement exp1 if divident subnormal
        end if;
      end if;
    when compute =>
      rnd_exp2 := zeros(12 downto 6) & r.lzcnt;
      if (r.faddd or r.muldiv) = '1' then
        rnd_exp2 := zeros(12 downto 1) & '1';
      end if;
    when normalize1 =>
      rnd_exp2 := (others => '0');
      rnd_exp2(0) := '1';
    when normalize2 =>
      rnd_exp2 := zeros(12 downto 6) & r.lzcnt;
    when roundm =>
      v.st := rounde;
    when rounde =>
      if r.man2(56) = '1'then
        rnd_exp2 := zeros(12 downto 1) & "1";
      else
        rnd_exp2 := (others => '0');
      end if;
    when rounds =>
      if (r.den and r.man2(55)) = '1'
      or (not r.den and r.man2(56)) = '1' then
        rnd_exp2 := zeros(12 downto 1) & "1";
      end if;
    when others =>
    end case;

-- 128-bit right shifter
    r_shift_out := std_logic_vector(
       SHIFT_RIGHT(unsigned(r.man2 & zeros(62 downto 0)),
       	to_integer(unsigned(r.shcnt))));

-- Extra bit right shift
    if (r.swap or r.fdsden) = '1' then
      r_shift_out := '0' & r_shift_out(119 downto 1);
    end if;

    r_shift_sticky_s := '0'; r_shift_sticky_d := '0';

    if fpga = 1 then -- calculate sticky with fast carry chain in fpgas
      stdp := std_logic_vector( unsigned("0" & ones(62 downto 0)) +
        unsigned("0" & r_shift_out(62 downto 0)));
      r_shift_sticky_d := stdp(63); -- dp sticky bit
      r_shift_sticky_s := r_shift_sticky_d and r.sp;
      stsp := std_logic_vector( unsigned("0" & ones(30 downto 0)) +
        unsigned("0" & r_shift_out(91 downto 61)));
      r_shift_sticky_s := r_shift_sticky_s or (r.sp and stsp(31)); -- sp sticky
    else -- fpga = 0, calculate sticky with comparator after shifting
      if r_shift_out(62 downto 0) /= zeros(62 downto 0) then
        r_shift_sticky_d := '1'; -- dp sticky bit
      end if;
      r_shift_sticky_s := r_shift_sticky_d and r.sp;
      if r_shift_out(91 downto 61) /= zeros(30 downto 0) then
        r_shift_sticky_s := r.sp; -- sp sticky bit
      end if;
    end if;
    if (r_shift_out(65 downto 63) /= "000") then
      r_shift_sticky := '1';
    else
      r_shift_sticky := r_shift_sticky_d;
    end if;

-- 57-bit mantissa add/sub
    if (r.msub = '0') then
      maddout := std_logic_vector(
        unsigned(r.man1) + unsigned(r.man2));
    else
      maddout := std_logic_vector(
        unsigned(r.man1) - unsigned(r.man2));
    end if;

-- 56-bit leading zero counter
    norm_lzcnt := "0000000";
    norm_lzcnt := clz64(r.man2(55 downto 0) & ones(63 downto 56));

-- 57-bit left shifter
    l_shift := std_logic_vector(SHIFT_LEFT(unsigned(r.man2),
    	to_integer(unsigned(r.lzcnt))));

-- exponent add/sub 2
    if r.esub = '1' then
      rnd_expres := std_logic_vector(unsigned(r.exp1) - unsigned(rnd_exp2));
    else
      rnd_expres := std_logic_vector(unsigned(r.exp1) + unsigned(rnd_exp2));
    end if;

-- add/sub/cmp state machine 2
    case r.st is
    when idle =>
      if expdiff1(11) = '1' then
        expdiff2 := not expdiff1;
      end if;
      if expdiff2(10 downto 6) /= unsigned(zeros(10 downto 6)) then
        expdiff2(5 downto 0) := (others => '1');
      end if;
      v.shcnt := expdiff2(5 downto 0);
      v.swap := swap;
      if r.fpld = '1' then
        if swap = '1' then
          v.sign := r.sign2;
        else
          v.sign := r.sign1;
        end if;
      end if;
      v.expdiff := expdiff1(11 downto 11);
      if (r.fdtos and swap) = '1' then
        v.shcnt := (others => '0');
        v.fdsden := '0';
      else
        v.fdsden := r.fdtos;
      end if;
      v.den := '0'; v.fstoiovf := '0';
      v.lzcnt := (others => '0');
      if r.fsqrtd = '0' then
        v.dx := v.nan1 or v.nan2 or v.inf1 or v.inf2 or v.zero1 or v.zero2;
      else
        v.dx := v.nan2 or v.inf2 or v.zero2 or r.sign2;
      end if;
      v.divstart := '0'; v.mulstart := '0';
    when align =>
      v.expdiff := expdiff1(11 downto 11);
      if (r.fstod or r.muldiv) = '1' then
        v.lzcnt := norm_lzcnt(5 downto 0);
      end if;
      if r.cmp = '1' then
        v.exp1 := '0' & std_logic_vector(expdiff1); -- FIX, maybe sign extend
        v.msel2 := adder;
        v.st := rounds;
      elsif r.fitod = '1' then
        v.sign := r.sign2;
        v.sub := '0';
        v.sp := r.fitos;
        if (r.ezero2 and r.mzero2 and not r.sign2) = '1' then
          v.nan := "01"; v.st := rounds;
        else
          v.st := compute; v.sub := '1'; v.esub := '1'; v.msub := '0';
          if r.fitos = '1' then v.exp1 := r.exp1 or ('0' & X"09C");
          else v.exp1 := r.exp1 or ('0' & X"41C"); end if;
          if r.exp1(1) = '0' then
            v.st := align;
            v.exp1(1) := r.exp1(2);
            v.msel2 := lefts;
            v.lzcnt := norm_lzcnt(5 downto 0);
          else
            v.msel2 := rights;
          end if;
        end if;
        v.shcnt := (others => '0');
      elsif r.fstod = '1' then
        v.sign := r.sign2; -- FIX is this necessary?
        if (r.zero2 or r.fdsden) = '1' then
          if r.fdtos = '0' then
            v.st := idle; v.busy := '0';
          end if;
          v.exp1 := (others => '0');
        else
          v.exp1 := rnd_expres;
        end if;
        if r.fdtos = '1' then
          v.msel2 := rights;
          v.msel1 := "01";
        else
          v.msel2 := man2;
        end if;
        v.esub := not r.fdtos;
        v.sp := r.fdtos;
        v.sub := '0'; v.msub := '0';
      elsif r.muldiv = '1' then
        v.sign := r.sign1 xor r.sign2;
        if r.dx = '1' then
          v.st := rounds; vdivrst := '1';
          if ((r.fmuld and r.fpinst(5)) = '1') and (fsmulden = 1) then
            v.sp := '0';
          end if;
        elsif r.mulstart = '0' then
          if ((r.swap and r.ezero1) or r.ezero2) = '1' then
            if r.man2(55) = '0' then
              v.lzcnt := norm_lzcnt(5 downto 0);
              v.msel2 := lefts; -- lshift
              v.esub := r.fmuld or r.fsqrtd;  -- add to exp during fdiv realignment
            else
              v.ezero1 := '0'; v.ezero2 := '0';
              v.exp1 := rnd_expres;
              v.esub := '0';
            end if;
          else
            v.mulstart := '1'; vmulstart := r.fmuld; vdivstart := r.fdivd;
            vsqrtstart := r.fsqrtd;
            v.exp1 := rnd_expres;
          end if;
          v.st := align;
        elsif (r.mulstart and divdecex) = '1' then
          v.exp1 := rnd_expres;
          v.st := align; v.msel1 := "00"; v.msel2 := man2;
        elsif (r.mulstart and not (mulbusy or divbusy)) = '1' then
          if r.sp = '0' then
            if r.fmuld = '1' then
              v.nx := mulres(1) or (mulres(2) or (mulres(3) and mulres(56)));
            else
              v.nx := divres(1) or (divres(2) or (divres(3) and divres(56)));
            end if;
          else
            if r.fmuld = '1' then
              v.nx := mulres(30) or (mulres(31) or (mulres(32) and mulres(56)));
            else
              v.nx := divres(30) or (divres(31) or (divres(32) and divres(56)));
            end if;
          end if;
          if r.fsqrtd = '1' then
            v.exp1 := '0' & rnd_expres(12 downto 1);
          else
            v.exp1 := rnd_expres;
          end if;
          v.msel1 := "01";
          if r.fmuld = '1' then v.msel2 := muld;
          else v.msel2 := divd; end if;
          v.esub := '0'; v.st := compute;
          v.mulstart := '0';
        else
          v.st := align; v.msel1 := "00"; v.msel2 := man2;
        end if;
      else
        v.msel2 := rights;
      end if;
      if r.fstoi = '1' then
        v.nx := r_shift_sticky;
      end if;
    when compute =>
      v.msel1 := "01"; v.msel2 := adder;
      norm_negate := r.sub and maddout(56);
      if (norm_negate = '1') then
        v.sign := not r.sign; -- subtract generated negative num
      else
        -- generate rounding bits for common add/sub/mul/div/sqrt
	      v.msel1 := "10";
        if r.sp = '0' then v.man1(3 downto 2) := "00";
	      else v.man1(32 downto 31) := "00"; end if;
        v.st := normalize1;
	      if maddout(56) = '0' then
          v.man1(4 downto 2) := '0' &
                rbit(r.rm, maddout(3 downto 0), r.sign, '0');
        else
          v.man1(4 downto 2) := '0' & rbit(r.rm, maddout(4 downto 2) &
                  (maddout(1) or maddout(0)), r.sign, '0');
	      end if;
--        if (r.fmuld = '1') and (r.man2(56 downto 55) /= "00") then v.man1(4 downto 2) := "000"; end if;
	      if r.sp = '1' then
	        if maddout(56) = '0' then
            v.man1(33 downto 31) := '0' &
              rbit(r.rm, maddout(32 downto 29), r.sign, '0');
	        else
            v.man1(33 downto 31) := '0' & rbit(r.rm, maddout(33 downto 31) &
                (maddout(30) or maddout(29)), r.sign, '0');
	        end if;
	      end if;
        v.msub := '0';
      end if;
      if r.sp = '1' then
        v.nx := r.nx or maddout(29);
      else
        v.nx := r.nx or maddout(0);
      end if;
      if ((r.nan1 or r.nan2 or r.inf1 or r.inf2) and not r.fitod) = '1' then 
        v.st := rounds; 
	      if ((r.sign1 = r.sign2) or (r.inf1 /= r.inf2)) and
		        ((r.nan1 or r.nan2) = '0')
	      then
          v.nan := "10"; v.nx := (r.inf1 and r.inf2) and (r.sign1 xor r.sign2);
	      else
          v.nan := "11"; v.sign := '0'; 
	        v.nv := (r.snan1 or r.snan2) or (r.inf1 and r.inf2); 
	        v.nx := '0';
	      end if;
      end if;
      if r.fitod = '1' then
        v.exp1 := rnd_expres;
        v.esub := '0';
      end if;
      if r.fstoi = '1' then
        -- detect fsdtoi overflow conditions
        if (((mzerofstoi /= '1')  -- res larger than 2**32
          or (r.man2(34) = '1')) -- positive int > 2**31
          and not ((r.sign2 = '1') and (mzerofstoi = '1') and -- largest neg int
            (r.man2(34) = '1') and (r.man2(33 downto 3) = zeros(33 downto 3))))
            or (r.expdiff(11) = '1') -- exp out of bounds
        then
          v.fstoiovf := '1';
        else
          v.fstoiovf := '0';
        end if;
        v.st := rounds;
      elsif (r.fstod and not r.fdtos) = '1' then
        v.msel2 := lefts; -- normalize de-norm op2 
        v.exp1 := rnd_expres;
        v.esub := '0'; v.sign := r.sign2;
      elsif r.muldiv = '1' then
        v.msel2 := adder; -- normal case, add round bits
        v.esub := '0'; v.exp2 := (others => '0');
        v.shcnt := unsigned(not r.exp1(5 downto 0));
        v.busy := '0'; v.st := idle;
--        if (r.exp1(12 downto 11) = "11") or
        if (r.exp1(11) = '1') or
          ((ezero1 and not r.man2(56))= '1')
        then -- flag denorm if negative exp or zero exp and no mant overflow
          v.msel2 := right1; v.den := '1';
          if (r.man2(56) = '1') then
            v.exp1 := rnd_expres;
            v.shcnt := unsigned(not rnd_expres(5 downto 0));
          end if;
          v.busy := '1'; v.st := normalize1;
        elsif (inf1 = '1') or ((r.sp = '1') and (r.exp1(9 downto 8) = "01")) or
          ((r.sp = '0') and (r.exp1(10 downto 1) = "1111111111")) or
         ((r.sp = '1') and (r.exp1(7 downto 1) = "1111111"))
        then -- needs additional rounding
          v.busy := '1'; v.st := normalize1; v.msel2 := man2;
        elsif (maddout(56) = '1') -- man overflow, add and shift right
          or  ((ezero1 and r.man2(56))= '1') then
          v.msel2 := addrs1;
          v.exp1 := rnd_expres;
          v.shcnt := unsigned(not rnd_expres(5 downto 0));
        elsif ((r.fmuld and r.fpinst(5)) = '1') and (fsmulden = 1) and
              ((r.man2(56 downto 55) = "00")) then
          v.st := normalize2; v.busy := '1'; v.esub := '1';
        end if;
      elsif (r.faddd and not norm_negate) = '1' then
        v.muldiv := '1';
        v.msub := '0';
        if (ezero1 = '1') then
          v.den := '1';
        end if;
        if ((maddout(56) and not r.sub) = '1') then
          v.msel2 := addrs1;
          v.exp1 := rnd_expres;
          v.den := '0';
        end if;
      end if;
      -- exit if additional rounding not necessary
      if ((r.faddd and not norm_negate) ) = '1' then
        if (((v.man1(3 downto 2) = "00") and (r.sp = '0')) or
           ((v.man1(32 downto 31) = "00") and (r.sp = '1'))) and
        (v.den = '0') and (v.nan = "00") and
        (((r.sp = '0') and (r.exp1(10 downto 1) /= "1111111111") and
          (r.exp1(12 downto 11) = "00")) or
         ((r.sp = '1') and (r.exp1(7 downto 1) /= "1111111") and
          (r.exp1(9 downto 8) = "00")))
        and (maddout(56 downto 55) /= "00")
        then
          v.st := idle; v.busy := '0';
          if r.sp = '1' then
            v.nx := v.nx or maddout(31) or maddout(30) or maddout(29);
            if maddout(56) = '1' then
              v.nx := v.nx or maddout(32);
            end if;
          else
            v.nx := v.nx or maddout(2) or maddout(1) or maddout(0);
            if maddout(56) = '1' then
              v.nx := v.nx or maddout(3);
            end if;
          end if;
        end if;
      end if;
      v.lzcnt := norm_lzcnt(5 downto 0);
    when normalize1 =>
      v.lzcnt := norm_lzcnt(5 downto 0);
      v.swap := '0';
      v.shcnt := r.shcnt;
      v.exp2 := r.exp1;
      if r.exp1(11 downto 6) /= "111111" then
        v.shcnt := (others => '1');
      end if;
      if ((ezero1 or not r.exp1(11)) or (r.sp and not r.exp1(8))) = '1' then
        v.shcnt := (others => '0');
      end if;

      if ((r.man2(56 downto 55) = "00") and 
         (((r.faddd or r.fdtos) and not r.fdsden) = '1'))
      then 
        v.st := normalize2;   --
	    elsif (((r.exp1(10 downto 1) = "1111111111") or ((r.exp1(7 downto 1) = "1111111") and (r.sp = '1'))) and ((r.man2(56) or r.man2(55)) = '1'))
        or ((r.muldiv and (r.exp1(11) or ezero1)) = '1')
        or ((r.muldiv and r.sp and (r.exp1(8) or ezero1)) = '1')
      then -- mant overflow
        v.st := roundm;
        if r.exp1(11) = '1' then v.swap := '1'; end if;
        if r.den = '1' then
          v.lzcnt := (others => '0');
          if r.man2(55) = '1' then
            v.msel2 := right1;
          end if;
        end if;
      else
        v.msel2 := adder; v.st := idle; v.busy := '0';
        if r.sp = '0' then
          v.nx := v.nx or r.man2(2) or r.man2(1) or r.man2(0);
        else
          v.nx := v.nx or r.man2(31) or r.man2(30) or r.man2(29);
        end if;
        if (maddout(56) = '1')
          or ((r.fdtos = '1') and (r.exp1(10 downto 0) = zeros(10 downto 0)))
        then
          if r.fdsden = '0' then
            v.msel2 := addrs1; v.exp1 := rnd_expres;
          else
            if maddout(55) = '1' then
              v.st := rounde; v.busy := '1'; v.man1(56) := '1';
              v.man1(32) := '0';
            end if;
          end if;
          if r.sp = '0' then
            v.nx := v.nx or maddout(3) or r.man1(3);
          else
            if r.fdsden = '1' then
              v.nx := v.nx or maddout(31) or r.man1(31);
            else
              v.nx := v.nx or maddout(32) or r.man1(32);
            end if;
          end if;
        end if;
      end if;
      v.unf := r.fdsden and v.nx;
      if (ezero1 and not mzero2 and not r.fdtos and not r.muldiv) = '1' then
        if v.busy = '1' then
          v.st := rounds;
        else
          v.st := idle;
        end if;
      end if;
      if r.fdtos = '1' then
        if ((r.swap or r.fdsden) = '0') and r.exp1(11 downto 10) = "00" then
          v.unf := '1'; v.nx := '1'; v.nan := "01";
          v.busy := '0'; v.st := idle;
        elsif (r.swap = '1') and
          ((r.exp1(11 downto 9) /= "000") or (r.exp1(8) = '1'))
        then
          v.ovf := '1'; v.nx := '1'; v.nan := "10";
          v.busy := '0'; v.st := idle;
        end if;
      end if;
      if r.muldiv = '1' then
        v.esub := '1'; v.unf := v.nx and (ezero1 and not rnd_expres(0));
      end if;
      if (r.exp1(12 downto 11) = "01")  -- detect ovf for mul/div
        or ((r.sp = '1') and (r.exp1(9 downto 8) = "01"))
      then
          v.ovf := '1'; v.nx := '1'; v.nan := "10";
          v.busy := '0'; v.st := idle;
      end if;
    when normalize2 =>  -- re-normalize subnormal if necessary
      v.msel1 := "01"; -- clear rounding bits
      v.msel2 := lefts;
      if rnd_expres(11) = '1' then
        v.st := denorm;
      else
        v.st := roundm;
      end if;
      v.msub := '0';
      v.exp2 := rnd_expres;
      if (r.fdtos = '0') then
        if rnd_expres(11) = '0' then
          v.exp1 := rnd_expres;
          if rnd_expres(11 downto 0) = X"000" then
            v.shcnt := "000001";
            v.den := '1';
          end if;
        else
          v.swap := '1';
          v.exp1 := (others => '0');
          v.shcnt := unsigned(not rnd_expres(5 downto 0));
          if rnd_expres(11 downto 6) /= "111111" then
            v.shcnt := (others => '1');
          end if;
        end if;
      end if;
      if r.lzcnt(5 downto 3) = "111" 
      then
        v.st := rounds;
        v.nan := "01";
        if (((r.zero1 and r.zero2) = '1') and (r.sign1 /= r.sign2))
          or (r.sub = '1')
        then
          v.sign := '0';
        if (r.rm = "11") then v.sign := r.sub; end if;
        end if;
      end if;

    when denorm =>  -- extra shift right for add/sub denorm undeflow results 
      v.st := roundm;
      v.msel2 := right1;
      v.shcnt := r.shcnt;
    when roundm => -- align mantissa with right shift in case of subnorm
      v.msel1 := "10";
      if (r.exp2(11) or r.den) = '1' then  -- exp underflow, denormalized result
        v.msel2 := rights; v.exp1 := (others => '0');
        v.den := '1';
      end if;
      v.man1(3 downto 2) := r.man1(3 downto 2) or
            rbit(r.rm, r_shift_out(63+3 downto 63), r.sign, r_shift_sticky_d);
      if r.sp = '1' then
        v.man1(32 downto 31) := r.man1(32 downto 31) or
            rbit(r.rm, r_shift_out(92+3 downto 92+0), r.sign, r_shift_sticky_s);
      end if;
      if r.sp = '0' then
        v.nx := r.nx or r.man2(2) or r.man2(1) or r.man2(0);
      else
        v.nx := r.nx or r.man2(31) or r.man2(30) or r.man2(29);
      end if;
      v.st := rounde;
      if r.fitod = '1' then
        v.sub := '0'; v.esub := '0';
      end if;
      if (r.faddd or r.muldiv) = '1' then
        v.esub := '0';
      end if;
    when rounde =>   -- round final mantissa, detect unf and ovf
      v.st := idle;
      v.msel2 := adder;
      v.busy := '0';
      if r.sp = '0' then
        v.nx := r.nx or r.man2(2) or r.man2(1) or r.man2(0);
      else
        v.nx := r.nx or r.man2(31) or r.man2(30) or r.man2(29);
      end if;
        if rnd_expres(12 downto 11) = "11" then   -- underflow, generate zero
	        v.nan := "01"; v.den := '0';
          v.unf := v.nx;
        end if;
        if (rnd_expres(12 downto 11) = "01") 
          or (inf1 = '1') -- this is needed for fdtos
        then
          v.nan := "10"; v.ovf := '1'; v.nx := '1';
        end if;
      if (rnd_expres(12 downto 0) = zeros(12 downto 0)) then
        v.unf := v.nx;
        if (r.den and maddout(55)) = '1' then
          v.st := rounds; v.busy := '1';
        end if;
      end if;
      if (not r.den and maddout(56)) = '1' then
          v.st := rounds; v.busy := '1';
      end if;

      if ((r.zero1 or r.zero2) and not r.fitod) = '1' then
        v.unf := '0'; v.nx := '0';
      end if;
      v.exp1 := rnd_expres;
    when rounds => 
      if r.cmp = '0' then
        v.exp1 := rnd_expres;
      else
        v.ezero1 := ezero1; v.mzero2 := mzero2;
      end if;
      if (r.den and r.man2(55)) = '1' then
        v.den := '0';
      end if;
      if r.fstoi = '1' then
        v.msel2 := man2; v.sp := '1';
        if (r.fstoiovf = '1') then
          v.nx := '0'; v.nv := '1'; -- inf on overflow
          if r.sub = '1' then
            v.nan := "01"; v.sign := '1';
          else
            v.nan := "10";
          end if;
        end if;
      end if;
      if (r.fsqrtd and r.dx) = '1' then
        if r.zero2 = '1' then	-- divisor zero, return inf
          v.nan := "01";
          v.sign := r.sign2;
        elsif ((r.nan2 or r.sign2) = '1') then
          v.nan := "11"; -- Nan, invalid op
          v.sign := r.sign2;
          v.nv := r.snan2 or (r.sign2 and not r.nan2);
        elsif r.inf2 = '1' then
          v.nan := "10";
        end if;
      end if;
      if (r.fdivd and r.dx) = '1' then
        if ((r.nan1 or r.nan2) = '1') or ((r.inf1 and r.inf2) = '1') then
          v.nan := "11"; -- Nan, invalid op
          v.sign := '0';
          v.nv := (r.inf1 and r.inf2) or r.snan1 or r.snan2;
        elsif (r.zero1 and r.zero2) = '1' then	-- divide 0/0, return Nan
          v.nan := "11";
          v.nv := '1';
          v.sign := '0';
        elsif r.zero2 = '1' then	-- divisor zero, return inf
          v.nan := "10";
          v.dz := not r.inf1;
        elsif r.inf1 = '1' then	-- dividend inf, return inf
          v.nan := "10";
        elsif ((r.zero1 or r.inf2) = '1') then	-- always zero
          v.nan := "01";
        end if;
      end if;
      if (r.fmuld and r.dx) = '1' then
        if ((r.nan1 or r.nan2) = '1') or 
           (((r.zero1 and r.inf2) or (r.zero2 and r.inf1)) = '1' )
--           or (((r.inf1 and r.inf2) = '1') and (r.sign1 /= r.sign2))
        then
          v.nan := "11"; -- Nan, invalid op
          v.sign := '0';
          v.nv := (r.inf1 and r.inf2) or r.snan1 or r.snan2
           or (r.zero1 and r.inf2) or (r.zero2 and r.inf1);
        elsif (r.inf1 or r.inf2) = '1' then	-- 
          v.nan := "10";
        elsif (r.zero1 or r.zero2) = '1' then	-- mul with 0, return 0
          v.nan := "01";
        end if;
      end if;
      if (r.muldiv and (r.den or ezero1)) = '1' then
        v.unf := r.nx and not r.ovf;
      end if;
	    if ((r.exp1(10 downto 1) = "1111111111") or 
         ((r.exp1(7 downto 1) = "1111111") and (r.sp = '1'))) 
         and ((r.man2(56) = '1')) and (v.nan = "00")
      then
        v.nan := "10"; v.ovf := '1'; v.nx := '1';
      end if;
      if (tinypostrnd = 1) then      -- optional tininess detected after rounding
        if (((r.den or r.fdsden) and r.man2(55)) = '1') and
          ((((r.man2(30) or r.man2(1)) = '1') and (r.rm = "00")) or -- rnd near
          (((((r.man2(2) = '1') and r.man2(1 downto 0) /= "00")) or -- rnd up/down
              ((r.man2(31) = '1') and (r.man2(30 downto 29) /= "00"))) and (r.rm(1) = '1'))
          or ((not r.den and not r.fdsden and r.man2(56)) = '1')) then
          v.unf := '0'; -- no underflow if denorm is rounded up to norm
        end if;   
      end if;
      v.st := idle;
      v.busy := '0';
    end case;

-- Swap operands during add/sub so that op2 has smallest operand
    if r.fpld = '1' then
      if r.fitod = '1' then v.msel2 := adder; end if;
      if swap = '1' then
        if r.fdtos = '0' then
          v.man1 := vmdop2; v.man2 := vmdop1;
        end if;
        v.exp2 := r.exp1; v.exp1 := r.exp2;
      else
        v.man1 := vmdop1; v.man2 := vmdop2;
      end if;
    end if;

    case v.msel1 is  -- mantissa1 mux
    when "00" =>                                 -- unmodified
    when "01" => v.man1 := zeros(56 downto 0);   -- all zeros
    when "10" =>                                 -- add rounding bits
      if r.sp = '0' then
        v.man1 := zeros(52 downto 1) & v.man1(4 downto 2) & "00";
      else
        v.man1 := zeros(52 downto 30) & v.man1(33 downto 31) & "00" &
		       "0" & X"0000000";
      end if;
    when others =>
      v.man1(56 downto 0) := '0' & l_shift(55 downto 0); -- re-align denorm
    end case;

    case v.msel2 is  -- mantissa2 mux
    when man2  =>                                      -- mantissa unmodified
    when rights =>
      v.man2 := '0' & r_shift_out(118 downto 63);      -- right shifter output
      v.man2(0) := v.man2(0) or r_shift_sticky_d;      -- and add sticky bits
      v.man2(29) := v.man2(29) or r_shift_sticky_s;
      if r.fstoi = '1' then
       if r.sub = '1' then v.man2(2 downto 0) := "000"; end if;
      end if;
	    if r.sp = '1' then v.man2(28 downto 0) := (others => '0'); end if;
    when adder => v.man2 := maddout;                    -- adder output
    when lefts => v.man2 := l_shift(56 downto 0);	      -- left shifter output
    when addrs1 => v.man2 := '0' & maddout(56 downto 1); -- adder right shift 1
    when right1 =>
      v.man2 := '0' & r.man2(56 downto 1); --mantissa right shift 1
      if r.sp = '0' then v.man2(0) := r.man2(1) or r.man2(0);
      else v.man2(29) := r.man2(30) or r.man2(29); end if; -- preserve sticky
    when divd => v.man2 := divres & '0'; -- divider result
	    if r.sp = '1' then
        v.man1(34 downto 31) := '0' &
                rbit2(r.rm, divres(33 downto 29), r.sign, '0', divres(56));
      else
        v.man1(5 downto 2) := '0' &
                rbit2(r.rm, divres(4 downto 1) & '0', r.sign, '0', divres(56));
      end if;
    when muld => v.man2 := mulres; -- multiplier result
	    if r.sp = '1' then
        v.man1(34 downto 31) := '0' &
                rbit2(r.rm, mulres(33 downto 29), r.sign, '0', mulres(56));
      else
        v.man1(5 downto 2) := '0' &
                rbit2(r.rm, mulres(4 downto 0), r.sign, '0', mulres(56));
      end if;
    end case;

    cman := r.man2;
    cexp := r.exp1(10 downto 0);
    aexc := r.unimp & r.nv & r.ovf & r.unf & r.dz & r.nx;

-- generate zero, inf and Nan results
   case r.nan is
    when "11" =>	-- Nan
      cman(54 downto 52) := "111";
      cman(51 downto 3) := (others => '0');
      cexp := (others => '1');
    when "10" =>	-- Inf
      cman(54 downto 3) := (others => '0');
      cexp := (others => '1');
      if (((r.rm = "01") and ((r.inf1 or r.inf2) = '0')) or
        ((r.rm = "10") and (r.sign = '1') and (r.ovf = '1')) or
        ((r.rm = "11") and (r.sign = '0') and (r.ovf = '1')))
        and (r.dz = '0') 
      then
        if r.fstoi = '0' then
          cexp(0) := '0';
        end if;
        cman(54 downto 3) := (others => '1');
      end if;
      if (r.fstoi and not r.sign) = '1' then
        cman(54 downto 32) := (others => '1'); -- max int fsdtoi
      end if;
    when "01" =>	-- Zero
      if r.den = '0' then
        cman(54 downto 3) := (others => '0');
      end if;
      cexp := (others => '0');
    when others =>	-- normal or inf
      if r.inf1 = '1' then
        cman(54 downto 3) := (others => '0');
        aexc := "001001";
      end if;
      if r.fstoi = '1' then
        cman(54 downto 32) := r.man2(25 downto 3);
        cexp(7 downto 0) := r.man2(33 downto 26); 
      end if;
    end case;

-- Generate condition codes for fcmps/fcmpd/fcmpes/fcmped
-- 00 : op1 = op2 ; 01 : op1 < op2 ; 10 : op1 > op2 ; 11 : unordered
-- invalid exception generated on signaling NaN or unordered fcmpes/fcmped

    fcc := "00"; sign2 := not r.sign2;
    if r.cmp = '1' then
      if (r.sign1 = '1') and (sign2 = '0') then
        fcc := "01";
      elsif (r.sign1 = '0') and (sign2 = '1') then
        fcc := "10";
      else
        fcc := (not r.sign) & r.sign;
      end if;
      aexc := "000000";
      if ((r.inf1 and r.inf2) = '1') then
        if r.sign1 = sign2 then
          fcc := "00";
        else
          fcc := sign2 & r.sign1;
        end if;
      elsif (r.nan1 or r.nan2) = '1' then
        fcc := "11";
        aexc(4) := r.snan1 or r.snan2 or r.fpinst(2);
      elsif ((r.inf1 or r.inf2) = '1') then
        if r.inf1 = '1' then
          fcc := not r.sign1 & r.sign1;
        elsif r.inf2 = '1' then
          fcc := sign2 & not sign2;
        else
          fcc := (not r.sign) & r.sign;
        end if;
      else
        if r.sign1 = sign2 then
          if r.ezero1 = '1' then
            if mzero = '1' then
              fcc := "00";
            else
              fcc := (not (r.man2(56) xor r.sign1)) & (r.man2(56) xor r.sign1);
            end if;
          else
            fcc := (not (r.exp1(11) xor r.sign1)) & (r.exp1(11) xor r.sign1);
          end if;
        else
          fcc := (not r.sign) & r.sign;
          if (r.ezero1 and mzero) = '1' then
            fcc := "00";    --   +0 = -0
          end if;
        end if;
      end if;
    end if;


    sqrtstart <= vsqrtstart;
    divstart <= vdivstart;
    mulstart <= vmulstart;
    divrst <= Reset or vdivrst;
    v.fpld := fpld and not r.fmov;

    if fpop = '1' then
      v.nan := "00"; v.inf1 := '0';  v.inf2 := '0';
      v.nv := '0'; v.ovf := '0'; v.unf := '0'; v.dz := '0'; v.nx := '0';
    end if;

    if Reset = '1' then
      v.fpop := '0'; v.fpld := '0'; v.st := idle; v.busy := '0';
      v.unimp := '0'; v.fmov := '0';
    end if;

    FracResult(54 downto 3) <= cman(54 downto 3);
    expres := (others => '0'); 
    expres(10 downto 0) := cexp;
    ExpResult <= expres(10 downto 0);
    excep <= aexc;
    ConditionCodes <= fcc;

    rin <= v;
  end process;

  reg : process (clock)
  begin 
    if rising_edge(clock) then 
      r <= rin; 
    end if;
  end process;

  FpBusy <= rin.busy or r.fpop when busydelay = 1 else r.busy;
  SignResult <= r.sign;
  SNnotDB <= r.sp;

end;

