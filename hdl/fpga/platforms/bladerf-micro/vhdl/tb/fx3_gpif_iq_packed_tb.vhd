-- Copyright (c) 2024 Nuand LLC
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library rtl_work;

library altera_lnsim;
    use altera_lnsim.altera_pll;

library nuand;
    use nuand.util.all ;
    use nuand.fifo_readwrite_p.all;
    use nuand.common_dcfifo_p.all;
    use nuand.bladerf_p.all;
    use nuand.fx3_gpif_p.all;

entity fx3_gpif_iq_packed_tb is
    generic (
        -- For bladeRF2 (2x2 MIMO):
        NUM_MIMO_STREAMS            : natural := 2;
        FIFO_READER_READ_THROTTLE   : natural := 0;

        ENABLE_CHANNEL_0            : std_logic := '1';
        ENABLE_CHANNEL_1            : std_logic := '1'
    );
end entity;

architecture arch of fx3_gpif_iq_packed_tb is

    -- bladerf-hosted uses ad9361.clock (125 MHz) for rx_clock and tx_clock
    constant SYSCLK_HALF_PERIOD     : time  := 1 sec * (1.0/125.0e6/2.0);

    -- For reasons unknown, simulation of this system in ModelSim requires that
    -- wrreq and data be asserted shortly before the rising clock edge. Sigh...
    constant FIFO_WORKAROUND        : time  := 1 ps;

    type fx3_control_t is record
        usb_speed   :   std_logic;
        tx_enable   :   std_logic;
        rx_enable   :   std_logic;
        meta_enable :   std_logic;
        packet      :   std_logic;
        highly_packed_mode : std_logic;
    end record;

    type fx3_gpif_t is record
        gpif_in     :   std_logic_vector(31 downto 0);
        gpif_out    :   std_logic_vector(31 downto 0);
        gpif_oe     :   std_logic;
        ctl_in      :   std_logic_vector(12 downto 0);
        ctl_out     :   std_logic_vector(12 downto 0);
        ctl_oe      :   std_logic_vector(12 downto 0);
    end record;

    signal sys_rst                  : std_logic := '1';
    signal done                     : boolean := false;

    signal fx3_pclk                 : std_logic := '1';
    signal fx3_pclk_pll             : std_logic := '1';
    signal sys_clk                  : std_logic := '1';

    signal pll_reset                : std_logic := '0';
    signal pll_locked               : std_logic := '0';
    signal fx3_control              : fx3_control_t;
    signal fx3_gpif                 : fx3_gpif_t;
    signal fx3_gpif_i               : std_logic_vector(31 downto 0);
    signal fx3_ctl_i                : std_logic_vector(12 downto 0);

    -- Control mapping
    alias dma0_rx_ack   is fx3_ctl_i( 0);
    alias dma1_rx_ack   is fx3_ctl_i( 1);
    alias dma2_tx_ack   is fx3_ctl_i( 2);
    alias dma3_tx_ack   is fx3_ctl_i( 3);
    alias dma_rx_enable is fx3_ctl_i( 4);
    alias dma_tx_enable is fx3_ctl_i( 5);
    alias dma_idle      is fx3_ctl_i( 6);
    alias system_reset  is fx3_ctl_i( 7);
    alias dma0_rx_reqx  is fx3_ctl_i( 8);
    alias dma1_rx_reqx  is fx3_ctl_i(12); -- due to 9 being connected to dclk
    alias dma2_tx_reqx  is fx3_ctl_i(10);
    alias dma3_tx_reqx  is fx3_ctl_i(11);

    signal loopback_i               : signed(15 downto 0) := (others =>'0');
    signal loopback_q               : signed(15 downto 0) := (others =>'0');
    signal loopback_valid           : std_logic           := '0';
    signal loopback_enabled         : std_logic           := '0';

    signal tx_clock             :   std_logic   := '1' ;
    signal rx_clock             :   std_logic   := '1' ;

    signal rx_sample_fifo           : rx_fifo_t           := RX_FIFO_T_DEFAULT;
    signal tx_sample_fifo           : tx_fifo_t           := TX_FIFO_T_DEFAULT;
    signal loopback_fifo            : loopback_fifo_t     := LOOPBACK_FIFO_T_DEFAULT;
    signal rx_meta_fifo             : meta_fifo_rx_t      := META_FIFO_RX_T_DEFAULT;
    signal tx_meta_fifo             : meta_fifo_tx_t      := META_FIFO_TX_T_DEFAULT;

    signal rx_mux_i                 : signed(15 downto 0);
    signal rx_mux_q                 : signed(15 downto 0);
    signal rx_mux_valid             : std_logic;

    signal tx_timestamp             : unsigned(63 downto 0)   := ( others => '0' );
    signal rx_timestamp             : unsigned(63 downto 0)   := ( others => '0' );

    constant FX3_HALF_PERIOD    :   time        := 1.0/(100.0e6)/2.0*1 sec ;
    constant TX_HALF_PERIOD     :   time        := 1.0/(9.0e6)/2.0*1 sec ;
    constant RX_HALF_PERIOD     :   time        := 1.0/(9.0e6)/2.0*1 sec ;

    signal dac_controls         :   sample_controls_t(0 to NUM_MIMO_STREAMS-1)  := (others => SAMPLE_CONTROL_DISABLE);
    signal dac_streams          :   sample_streams_t(dac_controls'range)        := (others => ZERO_SAMPLE);
    signal adc_controls         :   sample_controls_t(0 to NUM_MIMO_STREAMS-1)  := (others => SAMPLE_CONTROL_DISABLE);
    signal adc_streams          :   sample_streams_t(adc_controls'range)        := (others => ZERO_SAMPLE);

    signal tx_reset             :   std_logic := '0';
    signal tx_ts_reset          :   std_logic := '0';
    signal rx_reset             :   std_logic := '0';
    signal rx_ts_reset          :   std_logic := '0';

    signal meta_en_tx           :   std_logic := '0';
    signal meta_en_rx           :   std_logic := '0';

    signal rx_packet_control    :   packet_control_t := PACKET_CONTROL_DEFAULT;
    signal tx_packet_control    :   packet_control_t;

    signal trigger_signal_sync_tb     : std_logic;
    signal dac_stream_val_at_rx_enable : signed(15 downto 0) := ( others => '0' );

    function data_gen (count : natural) return std_logic_vector is
        variable msw, lsw : std_logic_vector(15 downto 0);
    begin
        msw := std_logic_vector(to_signed(count, 16));
        lsw := std_logic_vector(to_signed(-count, 16));

        return (msw & lsw);
    end function data_gen;

    signal rx_packet_ready      :   std_logic;

begin

    -- ========================================================================
    -- Brief summary of data flow
    -- ========================================================================
    --
    -- Simulated samples flow from fx3_model's TX side to its RX side. The
    -- validity of the data is checked there.
    --
    -- entity       U_fx3_model              FX3 model, TX process
    --  signal      fx3_gpif_i               fx3_gpif.gpif_oe is '0'
    --   process    register_gpif
    --  signal      fx3_gpif.gpif_in         Demuxed GPIF interface (FX3 -> FPGA)
    -- entity       U_fx3_gpif               GPIF implementation, write side
    --  signal      tx_sample_fifo.w*        TX fifo, write side
    -- entity       U_tx_sample_fifo
    --  signal      tx_sample_fifo.r*        TX fifo, read side
    --   process    tx_mux
    --  signal      loopback_fifo.w*         Loopback fifo, write side
    -- entity       U_rx_loopback_fifo
    --  signal      loopback_fifo.r*         Loopback fifo, read side
    --   process    loopback_fifo_control
    --  signal      loopback_{i,q,valid}
    --   process    rx_mux
    --  signal      rx_mux_{i,q,valid}
    -- entity       U_fifo_writer
    --  signal      rx_sample_fifo.w*        RX fifo, write side
    -- entity       U_rx_sample_fifo
    --  signal      rx_sample_fifo.r*        RX fifo, read side
    -- entity       U_fx3_gpif               GPIF implementation, read side
    --  signal      fx3_gpif.gpif_out        Demuxed GPIF interface (FPGA -> FX3)
    --   process    register_gpif
    --  signal      fx3_gpif_i               fx3_gpif.gpif_oe is '1'
    -- entity       U_fx3_model              FX3 model, RX process


    -- ========================================================================
    -- Instantiations
    -- ========================================================================

    -- Unit under test
    -- Clock domain: fx3_pclk_pll
    U_fx3_gpif : entity nuand.fx3_gpif
        port map (
            pclk                => fx3_pclk_pll,
            reset               => sys_rst,
            usb_speed           => fx3_control.usb_speed,
            gpif_in             => fx3_gpif.gpif_in,
            gpif_out            => fx3_gpif.gpif_out,
            gpif_oe             => fx3_gpif.gpif_oe,
            ctl_in              => fx3_gpif.ctl_in,
            ctl_out             => fx3_gpif.ctl_out,
            ctl_oe              => fx3_gpif.ctl_oe,
            tx_enable           => fx3_control.tx_enable,
            rx_enable           => fx3_control.rx_enable,
            meta_enable         => fx3_control.meta_enable,
            packet_enable       => fx3_control.packet,
            tx_fifo_write       => tx_sample_fifo.wreq,
            tx_fifo_full        => tx_sample_fifo.wfull,
            tx_fifo_empty       => tx_sample_fifo.wempty,
            tx_fifo_usedw       => tx_sample_fifo.wused,
            tx_fifo_data        => tx_sample_fifo.wdata,
            tx_timestamp        => tx_timestamp,
            tx_meta_fifo_write  => tx_meta_fifo.wreq,
            tx_meta_fifo_full   => tx_meta_fifo.wfull,
            tx_meta_fifo_empty  => tx_meta_fifo.wempty,
            tx_meta_fifo_usedw  => tx_meta_fifo.wused,
            tx_meta_fifo_data   => tx_meta_fifo.wdata,
            rx_fifo_read        => rx_sample_fifo.rreq,
            rx_fifo_full        => rx_sample_fifo.rfull,
            rx_fifo_empty       => rx_sample_fifo.rempty,
            rx_fifo_usedw       => rx_sample_fifo.rused,
            rx_fifo_data        => rx_sample_fifo.rdata,
            rx_meta_fifo_read   => rx_meta_fifo.rreq,
            rx_meta_fifo_full   => rx_meta_fifo.rfull,
            rx_meta_fifo_empty  => rx_meta_fifo.rempty,
            rx_meta_fifo_usedr  => rx_meta_fifo.rused,
            rx_meta_fifo_data   => rx_meta_fifo.rdata
        );

    -- Discrete control signals for fx3_gpif
    fx3_control.usb_speed   <= '0';
    fx3_control.meta_enable <= '0';
    fx3_control.packet      <= '0';
    fx3_control.highly_packed_mode <= '1';

    U_pkt_gen : entity nuand.rx_packet_generator
        port map(
            rx_clock           => rx_clock,
            rx_reset           => rx_reset,
            rx_enable          => fx3_control.rx_enable,
            rx_packet_enable   => fx3_control.packet,
            rx_packet_ready    => rx_packet_ready,
            rx_packet_control  => rx_packet_control
        );


    meta_en_tx <= fx3_control.meta_enable;
    meta_en_rx <= fx3_control.meta_enable;

    increment_tx_ts : process(tx_clock)
        variable ping : boolean := true ;
    begin
        if( rising_edge(tx_clock) ) then
            ping := not ping ;
            if( ping = true ) then
                tx_timestamp <= tx_timestamp + 1 ;
            end if ;
        end if ;
    end process ;

    increment_rx_ts : process(rx_clock)
        variable ping : boolean := true ;
    begin
        if( rising_edge(rx_clock) ) then
            ping := not ping ;
            if( ping = true ) then
                rx_timestamp <= rx_timestamp + 1 ;
            end if ;
        end if ;
    end process ;

    -- Model of FX3's GPIF interface
    -- Clock domain: fx3_pclk (source)
    U_fx3_model : entity nuand.fx3_model(micro_dma)
        port map (
            fx3_pclk            => fx3_pclk,
            fx3_gpif            => fx3_gpif_i,
            fx3_ctl             => fx3_ctl_i,
            fx3_uart_rxd        => '0',
            fx3_uart_txd        => open,
            fx3_uart_cts        => open,
            fx3_rx_en           => '1',
            fx3_rx_meta_en      => meta_en_rx,
            fx3_tx_en           => '1',
            fx3_tx_meta_en      => meta_en_tx,
            packed_mode_en      => fx3_control.highly_packed_mode,
            done                => done
        );

    -- Generate phase-shifted PLL clock
    U_fx3_pll : entity rtl_work.fx3_pll
        port map (
            inclk0   =>  fx3_pclk,
            areset   =>  pll_reset,
            c0       =>  fx3_pclk_pll,
            locked   =>  pll_locked
        );

    tx_clock    <= not tx_clock  after TX_HALF_PERIOD ;
    rx_clock    <= not rx_clock  after RX_HALF_PERIOD ;


    -- Reset handler
    sys_rst <= '0' after 100 ns;

    -- Generate system clock
    sys_clk <= not sys_clk after SYSCLK_HALF_PERIOD when not done else '0';


    tx_reset <= sys_rst;
    tx_ts_reset <= sys_rst;
    rx_reset <= sys_rst;
    rx_ts_reset <= sys_rst;

    meta_en_tx <= fx3_control.meta_enable;
    meta_en_rx <= fx3_control.meta_enable;

    -- TX Submodule
    U_tx : entity work.tx
        generic map (
            NUM_STREAMS          => dac_controls'length
        )
        port map (
            tx_reset             => tx_reset,
            tx_clock             => tx_clock,
            tx_enable            => fx3_control.tx_enable,

            meta_en              => meta_en_tx,
            timestamp_reset      => tx_ts_reset,
            usb_speed            => fx3_control.usb_speed,
            tx_underflow_led     => open,
            tx_timestamp         => tx_timestamp,

            -- Packing modes
            highly_packed_mode_en => fx3_control.highly_packed_mode,

            -- Triggering
            trigger_arm          => '0',
            trigger_fire         => '0',
            trigger_master       => '0',
            trigger_line         => open,

            -- Packet FIFO
            packet_en            => fx3_control.packet,
            packet_empty         => open,
            packet_control       => tx_packet_control,
            packet_ready         => '1',

            -- Samples from host via FX3
            sample_fifo_wclock   => fx3_pclk_pll,
            sample_fifo_wreq     => tx_sample_fifo.wreq,
            sample_fifo_wdata    => tx_sample_fifo.wdata,
            sample_fifo_wempty   => tx_sample_fifo.wempty,
            sample_fifo_wfull    => tx_sample_fifo.wfull,
            sample_fifo_wused    => tx_sample_fifo.wused,

            -- Metadata from host via FX3
            meta_fifo_wclock     => fx3_pclk_pll,
            meta_fifo_wreq       => tx_meta_fifo.wreq,
            meta_fifo_wdata      => tx_meta_fifo.wdata,
            meta_fifo_wempty     => tx_meta_fifo.wempty,
            meta_fifo_wfull      => tx_meta_fifo.wfull,
            meta_fifo_wused      => tx_meta_fifo.wused,

            -- Digital Loopback Interface
            loopback_enabled     => '0',
            loopback_fifo_wdata  => loopback_fifo.wdata,
            loopback_fifo_wreq   => loopback_fifo.wreq,
            loopback_fifo_wfull  => loopback_fifo.wfull,
            loopback_fifo_wused  => loopback_fifo.wused,

            -- RFFE Interface
            dac_controls         => dac_controls,
            dac_streams          => dac_streams
        );

    -- RX Submodule
    U_rx : entity work.rx
        generic map (
            NUM_STREAMS            => adc_controls'length
        )
        port map (
            highly_packed_mode_en  => fx3_control.highly_packed_mode,
            rx_reset               => rx_reset,
            rx_clock               => rx_clock,
            rx_enable              => fx3_control.rx_enable,

            meta_en                => meta_en_rx,
            timestamp_reset        => rx_ts_reset,
            usb_speed              => fx3_control.usb_speed,
            rx_mux_sel             => to_unsigned(0, 3),
            rx_overflow_led        => open,
            rx_timestamp           => rx_timestamp,

            -- Triggering
            trigger_arm            => '0',
            trigger_fire           => '0',
            trigger_master         => '0',
            trigger_line           => open,
            trigger_signal_sync_tb => trigger_signal_sync_tb,

            -- Packet FIFO
            packet_en              => fx3_control.packet,
            packet_control         => rx_packet_control,
            packet_ready           => rx_packet_ready,

            -- Samples to host via FX3
            sample_fifo_rclock     => fx3_pclk_pll,
            sample_fifo_raclr      => not fx3_control.rx_enable,
            sample_fifo_rreq       => rx_sample_fifo.rreq,
            sample_fifo_rdata      => rx_sample_fifo.rdata,
            sample_fifo_rempty     => rx_sample_fifo.rempty,
            sample_fifo_rfull      => rx_sample_fifo.rfull,
            sample_fifo_rused      => rx_sample_fifo.rused,

            -- Mini expansion signals
            mini_exp               => "00",

            -- Metadata to host via FX3
            meta_fifo_rclock       => fx3_pclk_pll,
            meta_fifo_raclr        => not fx3_control.rx_enable,
            meta_fifo_rreq         => rx_meta_fifo.rreq,
            meta_fifo_rdata        => rx_meta_fifo.rdata,
            meta_fifo_rempty       => rx_meta_fifo.rempty,
            meta_fifo_rfull        => rx_meta_fifo.rfull,
            meta_fifo_rused        => rx_meta_fifo.rused,

            -- Digital Loopback Interface
            loopback_fifo_wenabled => open,
            loopback_fifo_wreset   => tx_reset,
            loopback_fifo_wclock   => tx_clock,
            loopback_fifo_wdata    => loopback_fifo.wdata,
            loopback_fifo_wreq     => loopback_fifo.wreq,
            loopback_fifo_wfull    => loopback_fifo.wfull,
            loopback_fifo_wused    => loopback_fifo.wused,

            -- RFFE Interface
            adc_controls           => adc_controls,
            adc_streams            => adc_streams
        );

    -- ========================================================================
    -- Data converters
    -- ========================================================================

    gen_dac_controls : if( NUM_MIMO_STREAMS > 1 ) generate
        -- The TX side of the AD9361 HDL is a FIFO pull interface
        -- that expects a readahead FIFO. It toggles the data request
        -- signal every other cycle. This behavior is mimicked here.
        process( tx_clock, sys_rst )
        begin
            if( sys_rst = '1' ) then
                dac_controls <= (
                    0 => (enable => ENABLE_CHANNEL_0, data_req => '1'),
                    1 => (enable => ENABLE_CHANNEL_1, data_req => '1')
                );
            elsif( rising_edge(tx_clock) ) then
                for i in dac_controls'range loop
                    dac_controls(i) <= (
                        enable   =>     dac_controls(i).enable,
                        data_req => not dac_controls(i).data_req );
                end loop;
            end if;
        end process;
    else generate
        dac_controls <= (others => SAMPLE_CONTROL_ENABLE);
    end generate;

    gen_adc_controls : if( NUM_MIMO_STREAMS > 1 ) generate
        process( rx_clock, sys_rst )
            constant COUNT_RESET : integer := 0;
            variable count       : integer range -2047 to 2047 := COUNT_RESET;
        begin
            if( sys_rst = '1' ) then
                count := COUNT_RESET;
                adc_controls <= (
                    0 => (enable => ENABLE_CHANNEL_0, data_req => '1'),
                    1 => (enable => ENABLE_CHANNEL_1, data_req => '1')
                );
            elsif( rising_edge(rx_clock) ) then
                for i in adc_controls'range loop
                    adc_controls(i) <= (
                        enable   =>     adc_controls(i).enable,
                        data_req => not adc_controls(i).data_req );
                    if( adc_controls(i).enable = '1') then
                        if( adc_streams(i).data_v = '1' ) then
                           adc_streams(i).data_i <= to_signed(count, 16);
                           adc_streams(i).data_q <= to_signed(-count, 16);
                           if( count < 2047 ) then
                            count := count + 1;
                           else
                              count := COUNT_RESET;
                           end if;
                        end if;
                        adc_streams(i).data_v <= not adc_streams(i).data_v;
                    end if;
                end loop;
            end if;
        end process;
    else generate
        adc_controls <= (others => SAMPLE_CONTROL_ENABLE);
    end generate;

    -- ========================================================================
    -- Processes
    -- ========================================================================

    -- FX3 GPIF bidirectional signal control
    -- Adapted from same process in bladerf-hosted.vhd
    register_gpif : process(sys_rst, fx3_pclk_pll)
    begin
        if( sys_rst = '1' ) then
            fx3_gpif_i          <= (others => 'Z');
            fx3_gpif.gpif_in    <= (others => 'Z');
        elsif( rising_edge(fx3_pclk_pll) ) then
            fx3_gpif.gpif_in    <= fx3_gpif_i;

            if( fx3_gpif.gpif_oe = '1' ) then
                fx3_gpif_i      <= fx3_gpif.gpif_out;
            else
                fx3_gpif_i      <= (others =>'Z');
            end if;
        end if;
    end process;

    -- FX3 CTL bidirectional signals
    -- Adapted from same generator in bladerf-hosted.vhd
    generate_ctl : for i in fx3_ctl_i'range generate
        fx3_ctl_i(i) <= fx3_gpif.ctl_out(i) when fx3_gpif.ctl_oe(i) = '1' else 'Z';
    end generate;

    fx3_gpif.ctl_in <= fx3_ctl_i;

    -- Controller for loopback FIFO
    -- Stripped-down version of same process from rx.vhd
    loopback_fifo_control : process( sys_rst, loopback_fifo.rclock )
    begin
        if( sys_rst = '1' ) then
            loopback_enabled   <= '0';
            loopback_fifo.rreq <= '0';
            loopback_i         <= (others => '0');
            loopback_q         <= (others => '0');
            loopback_valid     <= '0';
        elsif( rising_edge(loopback_fifo.rclock) ) then
            loopback_enabled   <= '0';
            loopback_fifo.rreq <= '0';
            loopback_i         <= loopback_i;
            loopback_q         <= loopback_q;
            loopback_valid     <= '0';

            -- Is loopback enabled?
            loopback_enabled <= fx3_control.rx_enable;

            -- Do the loopback
            loopback_i     <= resize(signed(loopback_fifo.rdata(15 downto 0)), loopback_i'length);
            loopback_q     <= resize(signed(loopback_fifo.rdata(31 downto 16)), loopback_q'length);
            loopback_valid <= loopback_fifo.rreq and not loopback_fifo.rempty;

            -- Read from the FIFO if req'd
            loopback_fifo.rreq <= loopback_enabled and (not loopback_fifo.rempty);
        end if;
    end process;

    -- RX multiplexer
    -- Stripped-down version of same process from rx.vhd
    rx_mux : process(sys_rst, sys_clk)
    begin
        if( sys_rst = '1' ) then
            rx_mux_i     <= (others =>'0');
            rx_mux_q     <= (others =>'0');
            rx_mux_valid <= '0';
        elsif( rising_edge(sys_clk) ) then
            rx_mux_i     <= loopback_i;
            rx_mux_q     <= loopback_q;
            rx_mux_valid <= loopback_valid;
        end if;
    end process;

    -- TX multiplexer
    -- Stripped-down version of mimo_channel_sel_mux from tx.vhd
    --tx_mux : process( sys_clk )
    --begin
    --    if( rising_edge(sys_clk) ) then
    --        tx_sample_fifo.rreq <= not tx_sample_fifo.rempty;

    --        loopback_fifo.wdata <= tx_sample_fifo.rdata;
    --        loopback_fifo.wreq  <= tx_sample_fifo.rreq and not tx_sample_fifo.rempty;
    --    end if;
    --end process;


    -- ========================================================================
    -- Verification
    -- ========================================================================

    --
    -- Check for fullness on FIFOs
    --
    assert (rx_sample_fifo.wfull = '0') report "rx_sample_fifo full (write)" severity warning;
    assert (tx_sample_fifo.wfull = '0') report "tx_sample_fifo full (write)" severity warning;
    assert (loopback_fifo.wfull = '0') report "loopback_fifo full (write)" severity warning;

    -- Every three gpif transfers will contain 4 samples.
    -- Let's fill and check a 4 sample buffer every 3 pclk cycles.
    --
    -- Note: Failure expected after each fx3_model iteration since we lose
    -- sample continuity when fifo writer is disabled.
    look_for_dropped_rx_samples: process(fx3_pclk_pll)
        variable rx_val : integer;
        variable gpif_buffer_idx : integer range 0 to 2 := 0;
        variable buf_sc12q11 : std_logic_vector(3*fx3_gpif.gpif_out'length-1 downto 0) := (others => '0');
    begin
        -- Init rx_val
        if sys_rst = '1' then
            rx_val := 16#172# when ENABLE_CHANNEL_0 and ENABLE_CHANNEL_1 else 16#B9#;
        end if;

        if (rising_edge(fx3_pclk_pll)
            and fx3_gpif.gpif_oe = '1'
            and fx3_control.rx_enable = '1') then

            -- Shift in the new samples
            buf_sc12q11 := fx3_gpif.gpif_out & buf_sc12q11(buf_sc12q11'length-1 downto fx3_gpif.gpif_out'length);

            -- Checks the 4 sample buffer every 3 pclk cycles
            if gpif_buffer_idx = 2 then
                for i in 0 to 3 loop
                    assert(signed(buf_sc12q11(11+24*i downto 24*i))) = to_signed(rx_val, 12)
                        report "I expected: " & integer'image(rx_val) & ", Actual: " & integer'image(to_integer(signed(buf_sc12q11(11+24*i downto 24*i))))
                        severity failure;
                    assert(signed(buf_sc12q11(23+24*i downto 12+24*i))) = to_signed(-1*rx_val, 12)
                        report "Q expected: " & integer'image(-1*rx_val) & ", Actual: " & integer'image(to_integer(signed(buf_sc12q11(23+24*i downto 12+24*i))))
                        severity failure;
                    rx_val := (rx_val + 1) mod 2048;
                end loop;
            end if;

            gpif_buffer_idx := (gpif_buffer_idx + 1) mod 3;
        end if;
    end process look_for_dropped_rx_samples;

    look_for_dropped_tx_samples: process(tx_clock)
        variable tx_val : integer := 0;
        variable message_count : integer := 1;
        variable q_expected : integer := 0;
        variable valid_tx_count : integer := 0;
    begin
        if rising_edge(tx_clock) then
            for i in dac_controls'range loop
                if dac_streams(i).data_v = '1' then
                    q_expected := tx_val+1 when fx3_control.highly_packed_mode = '1'
                                  else to_integer(to_signed(message_count,8) & to_signed(tx_val+1, 8));

                    assert(dac_streams(i).data_i = to_signed(tx_val, 16))
                        report "TX("&integer'image(i)&") I expected: " & integer'image(tx_val) & ", Actual: " & integer'image(to_integer(signed(dac_streams(i).data_i)))
                        severity failure;
                    assert(dac_streams(i).data_q = q_expected)
                        report "TX("&integer'image(i)&") Q expected: " & integer'image(q_expected) & ", Actual: " & integer'image(to_integer(signed(dac_streams(i).data_q)))
                        severity failure;

                    -- A new message is received every 2048 samples
                    valid_tx_count := valid_tx_count + 1;
                    if valid_tx_count mod 2048 = 0 then
                        message_count := message_count + 1;
                    end if;

                    tx_val := (tx_val + 2) when tx_val < 2046 else -2048;
                end if;
            end loop;
        end if;
    end process look_for_dropped_tx_samples;

end architecture;
