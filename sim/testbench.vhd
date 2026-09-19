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
-- Reads operands from filename and checks results
------------------------------------------------------------------------------
-- Entity: 	testbench
-- Author:	Jiri Gaisler
-- Version: 1.0
------------------------------------------------------------------------------

library ieee;
use ieee.Std_Logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.stdlib.all;
use work.stdio.all;

entity testbench is
  generic (
    fpga : integer := 0;      -- enable fpga optimization for irisfpu
    busydelay : integer := 1; -- 1 for meiko compatibility
    srt : integer range 0 to 3 := 3; -- 3=fastest
    tinypostrnd : integer range 0 to 1 := 0;  -- detect tininess after rounding
    fsmulden  : integer range 0 to 1 := 1; -- enable FSMULD instruction
    filename : string := "testfloat.txt"; -- testvector file
    opcode : integer := 0; -- force opcode
    rm : integer := 0;    -- force rounding mode
    tf : integer := 0;    -- 1 = force testfloat exception bits order
    noerr : integer := 0; -- dont stop on errors
    log : integer := 0    -- print vectors to console
  );
end; 

architecture behav of testbench is
signal clk : std_logic := '1';
signal rstn : std_logic := '0';
signal in1, in2 : std_logic_vector(63 downto 0);
signal sub : std_logic := '0';
signal check : std_logic := '0';
signal ready : std_logic;
signal val, res, res3 : std_logic_vector(63 downto 0);
signal vals : std_logic_vector(31 downto 0);
signal excep : std_logic_vector(5 downto 0);
signal cc : std_logic_vector(3 downto 0);
signal fop : std_logic_vector(11 downto 0);
file vfile: text;
signal fpop, fpld, fpbusy, fpbusy2, sign, snnotdb, rst : std_logic;
signal din1, din2 : std_logic_vector(63 downto 0);
signal fracres : std_logic_vector(54 downto 3);
signal expres : std_logic_vector(10 downto 0);
signal rmode : std_logic_vector(1 downto 0) := "00";
signal runtest : boolean := true;

begin

-- clock and reset

  clk <= not clk after 5 ns when runtest;
  rstn <= '1' after 150 ns;
  rst <= not rstn;
  din1 <= in1;
  din2 <= in2;

  fpu0 : entity work.irisfpu
    generic map (fpga, busydelay, srt, tinypostrnd, fsmulden)
    port map (clk, fop(9 downto 0), fpop, fpld, rst, din1, din2, rmode,
      fpbusy, fracres, expres, sign, snnotdb, excep, cc(1 downto 0));

  vals <= sign & expres(7 downto 0) & fracres(54 downto 32);
  val <= sign & expres(10 downto 0) & fracres(54 downto 3);
  cc(3 downto 2) <= "00";
  main : process
  function isnand(s : std_logic_vector(63 downto 0); sig : boolean) return boolean is
  begin
    if sig then
      return ((s(62 downto 52) = ("111" & X"FF")) and (s(51) = '0') and
       (s(51 downto 0) /= (X"0000000000000"))); 
    else
      return ((s(62 downto 52) = ("111" & X"FF")) and (s(51) = '1') and
       (s(51 downto 0) /= (X"0000000000000"))); 
    end if;
  end;
  function isnans(s : std_logic_vector(31 downto 0); sig : boolean) return boolean is
  begin
    if sig then
      return ((s(30 downto 23) = X"FF") and (s(22) = '0') and 
        (s(22 downto 0) /= ("000" & X"00000"))); 
    else
      return ((s(30 downto 23) = X"FF") and (s(22) = '1') and 
        (s(22 downto 0) /= ("000" & X"00000"))); 
    end if;
  end;
  variable op1, op2, calc, res2 : std_logic_vector(63 downto 0);
  variable op1s, op2s, calcs : std_logic_vector(31 downto 0);
  variable LR:      Line;
  variable opfi : integer := 0;
  variable i : integer := 1;
  variable opf : std_logic_vector(11 downto 0);
  variable cexc, tmp : std_logic_vector(7 downto 0);
  variable fcc_ref, Round, c1 : std_logic_vector(3 downto 0);
  variable tfi, ops, opd, resd, ress, fcc_res : integer := 0;
  variable err : boolean := false;
  variable L : line;
  variable wres : string(1 to 14) := "Wrong result: ";
  variable wfcc : string(1 to 11) := "Wrong fcc: ";
  variable wexc : string(1 to 17) := "Wrong exception: ";

  begin
    tfi := tf; opfi := opcode;
    if runtest then File_Open(vfile, filename, Read_Mode); end if;
	  rmode <= conv_std_logic_vector(rm, 2);
    sub <= '0';
    fpop <= '0';
    fpld <= '0';
	  opf := conv_std_logic_vector(opfi, 12);
    fop <= X"000";
    if runtest then wait for 205 ns; end if;
    wait on clk until rising_edge(clk);
    if runtest then print("Reading data from " & filename); end if;
    while not endfile(vfile) and runtest loop
      ReadLine(vfile, LR);
      ops := 0; ress := 0; opd := 0; resd := 0; fcc_res := 0;
      if opfi = 0 then HRead(LR, opf(11 downto 8)); end if;
      if (opf(11 downto 8) = X"F") then    -- commands to the testbench
        HRead(LR, opf(7 downto 0));
        case opf(1 downto 0) is
        when "01" =>
          HRead(LR, Round);
	        rmode <= Round(1 downto 0);
          print("Setting rounding mode to " & tost(Round));
        when "10" =>
          print("Setting exception bits to testfloat order");
          tfi := 1;
        when "11" =>
          HRead(LR, opf);
          print("Setting operation to " & tost(opf));
          opfi := 1;
        when others =>
        end case;
      else
        if (opfi = 0) then -- read opcode unless given in generic
          HRead(LR, opf(7 downto 0));
        end if;
        -- calculate type and number of operands
        if (opf(7 downto 6) = "11")
           or opf(7 downto 4) = "0010" -- single operand fitod, fdtos, fsqrt ..
        then
          if opf(1) = '1' then opd := 1;
          else ops := 1; end if;
          if (opf(3) = '1') and opf(7 downto 0) /= X"29" then
            resd := 1;
          else ress := 1; end if;
        elsif (opf(8 downto 4) = "00000") then -- fmove, fabs, fneg
          ops := 1; ress := 1;
        else
          if (opf(1) = '0') then    -- single precision operands
            ops := 2; ress := 1;
            if (opf(7 downto 0) = X"69") then -- fsmuld
              resd := 1; ress := 0;
            end if;
          else
            opd := 2; resd := 1;
          end if;
          if (opf(7 downto 4) = X"5") then
            ress := 0; resd := 0; fcc_res := 1;
          end if;
        end if;
        if ops = 1 then
          HRead(LR, op2s);
          op2 := op2s & op2s;
        end if;
        if ops = 2 then
          HRead(LR, op1s); HRead(LR, op2s);
          op1 := op1s & op1s;
          op2 := op2s & op2s;
        end if;
        if opd = 1 then HRead(LR, op2); end if;
        if opd = 2 then HRead(LR, op1); HRead(LR, op2); end if;
        if ress = 1 then HRead(LR, calcs); end if;
        if resd = 1 then HRead(LR, calc); end if;
        if fcc_res = 1 then HRead(LR, fcc_ref); end if;
        HRead(LR, tmp);

        fop <= opf;
        fpop <= '1';
        wait on clk until rising_edge(clk);
        fpop <= '0';
        fop <= (others => '0');
        in1 <= op1;
        in2 <= op2;
        fpld <= '1';
        wait on clk until rising_edge(clk);
        if tfi = 1 then    -- testfloat generated exceptions in different order
          cexc := "000" & tmp(4) & tmp(2) & tmp(1) & tmp(3) & tmp(0);
        else
          cexc := tmp;
        end if;
        res <= calc;
        fpld <= '0';
        wait on clk until rising_edge(clk);
        if fpbusy = '1' then
          wait on fpbusy until fpbusy ='0';
        else
          wait on clk until rising_edge(clk);
        end if;
        if (busydelay = 1) then
          wait on clk until rising_edge(clk);
        end if;
--        wait on clk until falling_edge(clk);
        wait for 1 ns;
        if (i mod 100000) = 0 then
          print("vector: " & tost(i));
        end if;
        if (noerr = 0) then
          if ((ress = 1) and 
            ((calcs /= vals) and 
                  (not (isnans(vals, false) and isnans(calcs, false))) 
              and (not (isnans(vals, true) and isnans(calcs, true))))) 
            or ((resd = 1) and 
             ((calc /= val) and not (isnand(val, false) or isnand(calc, false))))
          then
            write(L, wres);
            err := true;
          elsif (fcc_res = 1) and (cc(1 downto 0) /= fcc_ref(1 downto 0)) then
            write(L, wfcc);
            err := true;
          elsif (excep(4 downto 0) /= cexc(4 downto 0)) then
            write(L, wexc);
            err := true;
          end if;
        end if;
        if err or (log = 1) then
          write(L, tost(opf) & " ");
          if ops = 1 then
            write(L, tost(op2s) & " ");
          elsif ops = 2 then
            write(L, tost(op1s) & " " & tost(op2s) & " ");
          elsif opd = 1 then
            write(L, tost(op2) & " ");
          elsif opd = 2 then
            write(L, tost(op1) & " " & tost(op2) & " ");
          end if;

          if ress = 1 then
            write(L, tost(vals) & " ");
            if err then write(L, tost(calcs) & " "); end if;
          elsif resd = 1 then
            write(L, tost(val) & " ");
            if err then write(L, tost(calc) & " "); end if;
          end if;
          if fcc_res = 1 then
            write(L, tost(cc) & " ");
            if err then write(L, tost(fcc_ref) & " "); end if;
          end if;
          write(L, tost(excep));
          if err then write(L, " " & tost(cexc)); end if;

          writeline(output, L);
          assert not err
          report "testbench " & filename & " failed at line: " & tost(i)
          severity failure; 
          err := false;
        end if;
--        wait on clk until falling_edge(clk);
      end if;
      i := i + 1;
    end loop;
    if runtest then
      print("vector: " & tost(i));
      print("Test ended successfully");
    end if;
    runtest <= false;
    wait for 50 ns;
--    assert false report "End of data" severity failure; wait;
  end process;

end;


