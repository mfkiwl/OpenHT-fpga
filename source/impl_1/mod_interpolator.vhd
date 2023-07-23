-------------------------------------------------------------
-- Mod interpolator
-- Number of Taps must be divisible by L
--
-- Sebastien Van Cauwenberghe, ON4SEB
--
-- M17 Project
-- July 2023
-------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.axi_stream_pkg.all;
use work.openht_utils_pkg.all;

entity mod_interpolator is
  generic
  (
    N_TAPS : natural; --!!! TAPS count must be a multiple of L
    L      : natural; -- Interpolation factor
    C_TAPS : taps_mod_t -- TAPS value
  );
  port
  (
    clk_i        : in std_logic;
    s_axis_mod_i : in axis_in_mod_t;
    s_axis_mod_o : out axis_out_mod_t;
    m_axis_mod_o : out axis_in_mod_t;
    m_axis_mod_i : in axis_out_mod_t
  );
end entity mod_interpolator;

architecture rtl of mod_interpolator is
    constant C_BUFFER_SIZE : natural := N_TAPS / L;

    type interp_state_t is (IDLE, START_COMPUTE, FIR_COMPUTE, OUTPUT_DATA);
    signal interp_state : interp_state_t := IDLE;
    signal interp_round : unsigned(3 downto 0);
    signal tap_addr    : unsigned(log2up(N_TAPS)-1 downto 0);
    signal data_counter : unsigned(log2up(C_BUFFER_SIZE)-1 downto 0);

    signal accumulator : signed(39 downto 0) := (others => '0');
    signal accumulate_0 : std_logic;
    signal accumulate_1 : std_logic;

    signal coeff_data : signed(15 downto 0);
    signal buffer_rddata : signed(15 downto 0);

    signal multiply_out : signed(31 downto 0);

    type buffer_data_t is array (0 to 2**log2up(C_BUFFER_SIZE)-1) of signed(s_axis_mod_i.tdata'range);
    signal buffer_data : buffer_data_t;
    signal buffer_wrptr : unsigned(log2up(C_BUFFER_SIZE)-1 downto 0) := (others => '0');
    signal round_rdptr : unsigned(log2up(C_BUFFER_SIZE)-1 downto 0) := (others => '0');
    signal buffer_rdptr : unsigned(log2up(C_BUFFER_SIZE)-1 downto 0) := (others => '0');

begin

    assert N_TAPS mod L = 0 report "Taps count must be a multiple of L" severity error;
    assert C_TAPS'length = N_TAPS report "Taps not the same size as the declared number" severity error;

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            -- Write data
            if s_axis_mod_i.tvalid and s_axis_mod_o.tready then
                buffer_data(to_integer(buffer_wrptr)) <= signed(s_axis_mod_i.tdata);
                buffer_wrptr <= buffer_wrptr + 1;
                round_rdptr <= buffer_wrptr;
            end if;

            buffer_rddata <= buffer_data(to_integer(buffer_rdptr));
            coeff_data <= C_TAPS(to_integer(tap_addr));
        end if;
    end process;

    multiply_out <= coeff_data * buffer_rddata;

    process (clk_i)
    begin
        if rising_edge(clk_i) then
        s_axis_mod_o.tready <= '0';
        accumulate_1 <= accumulate_0;

        if accumulate_1 then
            accumulator <= accumulator + ((7 downto 0 => multiply_out(multiply_out'high)) & multiply_out);
        end if;

        case interp_state is
            when START_COMPUTE =>
                data_counter <= (others => '0');
                buffer_rdptr <= round_rdptr;
                interp_state <= FIR_COMPUTE;

            when FIR_COMPUTE =>
                accumulate_0 <= '1'; -- Accumulate

                -- Compute N samples FIR
                if data_counter < (N_TAPS/L) - 1 then
                    tap_addr <= tap_addr + L;
                    data_counter <= data_counter + 1;
                    buffer_rdptr <= buffer_rdptr - 1;
                else
                    interp_state        <= OUTPUT_DATA;
                    interp_round        <= interp_round + 1;
                    accumulate_0 <= '0'; -- Stop accumulation
                end if;

            when OUTPUT_DATA => -- Wait until acc is ready
                data_counter <= (others => '0');
                buffer_rdptr <= round_rdptr;
                if not accumulate_1 then
                    m_axis_mod_o.tdata <= std_logic_vector(accumulator(39 downto 24));
                    m_axis_mod_o.tvalid <= '1';
                end if;

                -- Wait for data to be accepted by downstream
                if m_axis_mod_i.tready and m_axis_mod_o.tvalid then
                    m_axis_mod_o.tvalid <= '0';
                    accumulator <= (others => '0');
                    if interp_round < L then
                        interp_state                 <= FIR_COMPUTE;
                        tap_addr                     <= (others => '0');
                        tap_addr(interp_round'range) <= interp_round;
                    else
                        interp_state <= IDLE;
                    end if;
                end if;

            when others => -- IDLE
                s_axis_mod_o.tready <= '1';
                interp_round        <= (others => '0');
                tap_addr           <= (others => '0');
                data_counter <= (others => '0');
                accumulate_0 <= '0';

                -- When new data comes in, start to compute
                if s_axis_mod_i.tvalid and s_axis_mod_o.tready then
                    s_axis_mod_o.tready <= '0';
                    interp_state <= START_COMPUTE;
                end if;
        end case;
    end if;
  end process;

end architecture;
