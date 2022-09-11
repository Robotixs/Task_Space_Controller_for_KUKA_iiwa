%% Task-space trajectory tracking for redundant robot (sliding mode controller)
% @author: yanjun liu 
% @date: June, 2022
% @descriptions:
% This scripts implements sliding mode control for trajectory tracking.
% Cartesian pose (position+orientation) controller is implemented.
% Sliding mode vector is defined as:
% [joint-space] s = qdot-rqdot = qdot-(dqdot-gamma*(q-dq))
% [task-space]  s = qdot-rqdot = qdot-invJ*(dxdot-gamma*(x-dx))
% Control law is defined with sign function as switching function:            
% => tau = M*qdotdot_c + C + G - k * sgn(s);
% ==> qdotdot_c = J#(xdotdot_c - J_dot*qdot);
% ==> xdotdot_c = xdotdot_d + Kx*(dx-x) + Dx*(-J*qdot), while desired trajectory is given
% @references: Applied Nonlinear Control by Jean-Jacques Slotine, Weiping Li.
clear; clc; close all;
addpath('..\..\libs');

%% LOAD ROBOT
lbr = importrobot('iiwa14.urdf');
lbr.DataFormat = 'column';
lbr.Gravity = [0 0 -9.81];
forceLimit = 5000;
displayOn = false;
jointNum = 7;

%% CONNECT TO VREP
vrep = remApi('remoteApi'); % using the prototype file (remoteApiProto.m)
% close all the potential link
vrep.simxFinish(-1);
% wait for connecting vrep, detect every 0.2s
while true
    clientID = vrep.simxStart('127.0.0.1', 19999, true, true, 5000, 5);
    if clientID > -1 
        break;
    else
        pause(0.2);
        disp('please run the simulation on vrep...')
    end
end
disp('Connection success!')
% set the simulation time step: 5ms per simulation step
tstep = 0.005;
vrep.simxSetFloatingParameter(clientID, vrep.sim_floatparam_simulation_time_step, tstep, vrep.simx_opmode_oneshot);
% open the synchronous mode to control the objects in vrep
vrep.simxSynchronous(clientID, true);

%% SIMULATION INITIALIZATION
vrep.simxStartSimulation(clientID,vrep.simx_opmode_oneshot);
% get the joint handles: joint 1~7
jointName = 'iiwa_joint_';
jointHandle = zeros(jointNum,1); % column vector
for i = 1:jointNum 
    [res, returnHandle] = vrep.simxGetObjectHandle(clientID, [jointName, int2str(i)], vrep.simx_opmode_blocking);
    if res == 0
        jointHandle(i) = returnHandle;
    else
        fprintf('can not get the handle of joint %d!!!\n', i);
    end
end
% get the ee handle
[res, eeHandle] = vrep.simxGetObjectHandle(clientID, 'iiwa_link_ee_kuka_visual', vrep.simx_opmode_blocking);
if res == 0
    jointHandle(i) = returnHandle;
else
    fprintf('can not get the handle of ee %d!!!\n', i);
end
vrep.simxSynchronousTrigger(clientID);
disp('Handles available!')

%% SET DATASTREAM
% NOTE: 
% datastream mode set to simx_opmode_streaming for the first call to read
% the joints' configuration, afterwards set to simx_opmode_buffer
jointPos = zeros(jointNum, 1);	% joint position
jointVel = zeros(jointNum, 1);	% joint velocity
jointTau = zeros(jointNum, 1); 	% joint torque
for i = 1:jointNum
    [~, jointPos(i)] = vrep.simxGetJointPosition(clientID, jointHandle(i), vrep.simx_opmode_streaming);
    [~, jointVel(i)] = vrep.simxGetObjectFloatParameter(clientID, jointHandle(i), 2012, vrep.simx_opmode_streaming);
    [~, jointTau(i)] = vrep.simxGetJointForce(clientID, jointHandle(i), vrep.simx_opmode_streaming);
end
% end effector position (x-y-z coordinates) and its orientation (alpha,beta,gamma)
[~, eePos] = vrep.simxGetObjectPosition(clientID, eeHandle, -1, vrep.simx_opmode_streaming);
[~, eeEuler] = vrep.simxGetObjectOrientation(clientID, eeHandle, -1, vrep.simx_opmode_streaming);
eePos = eePos';
eeEuler = eeEuler';
% get simulation time
currCmdTime = vrep.simxGetLastCmdTime(clientID) / 1000;
lastCmdTime = currCmdTime;
vrep.simxSynchronousTrigger(clientID);         % every time we call this function, verp is triggered

%% DATA LOGGER
Q = []; QDOT = []; 	% joint position and velocity
DX = []; X = [];	% desired cartesian position and real cartesian position
U = [];				% joint torque
T = [];				% time elapse
ERR = []; 			% cartesian position error

%% PD CONTROLLER
% saturation function for sliding mode
% for P part in first-order inverse kinematics
K_x1 = [800*eye(3), zeros(3); zeros(3), 4000*eye(3)];
% for D part in second-order inverse kinematics
D_x2 = [57*eye(3), zeros(3); zeros(3), 125*eye(3)];
% for P part in second-order inverse kinematics
K_x2 = [800*eye(3), zeros(3); zeros(3), 4000*eye(3)];
% for sliding mode regulator gain
% with greater K_s, there will be greater vibrations
K_s = 0.2*eye(7);      

%% SIMULATION STARTS
disp('being in loop!');
t = 0; tInit = 0;
while ((vrep.simxGetConnectionId(clientID) ~= -1) && (t<5))  % vrep connection is still active    
    %% 0. time update
    currCmdTime = vrep.simxGetLastCmdTime(clientID) / 1000;
    dt = currCmdTime - lastCmdTime;               % simulation step, unit: s 
    
	%% 1. read state variables from sensors
    % joint position and velocity
    for i = 1:jointNum
        [~, jointPos(i)] = vrep.simxGetJointPosition(clientID, jointHandle(i), vrep.simx_opmode_buffer);
        [~, jointVel(i)] = vrep.simxGetObjectFloatParameter(clientID, jointHandle(i), 2012, vrep.simx_opmode_buffer);
    end
    % end-effector's cartesian position and orientation
    [~, eePos] = vrep.simxGetObjectPosition(clientID, eeHandle, -1, vrep.simx_opmode_buffer);
    [~, eeEuler] = vrep.simxGetObjectOrientation(clientID, eeHandle, -1, vrep.simx_opmode_buffer);
    eePos = eePos';
    eeEuler = eeEuler';
	
	%% 2. set desired cartesian trajectory (position, velocity and acceleration)
    % initial position needs to be set at [0.5;0;0.5]
    dx = 0.5 * ones(3, 1); dx(2) = 0.05 * sin(2*pi*(t-tInit));
    dxdot = [0, 0.05*2*pi*cos(2*pi*(t-tInit)), 0]';
    dxdotdot = [0, -0.05*4*pi^2*sin(2*pi*(t-tInit)), 0]';
    if ~exist('dEuler', 'var')
        dEuler = eeEuler;
    end

    %% 3. integrate torque for trajectory tracking control
    % collect state variables
    q = jointPos; qdot = jointVel;
    x = eePos; % x_dot = J * qdot
	% model-based dynamics and compensation
    G = gravityTorque(lbr, q);
    C = -velocityProduct(lbr, q, qdot);
	M = massMatrix(lbr, q);
	
	%% 3-a. figure out geometric Jacobian and sliding mode vector
	% Jacobian differenation, `dJ/dt = ∂J/∂q * ∂q/dt = ∂J/∂q * dq/dt = ∂(J*qdot)/∂q`
	[geometryJacobian, geometryJacobian_dot] = JacobianDerivative(lbr, q, qdot);
    % NOTE THAT: Moore-Penrose of translational Jacobian in two methods
	% ***** (1) inertial-weighted generalized inverse Jacobian *****
    % % transJacobian_inv = (M \ transJacobian') / ((transJacobian / M) * transJacobian');
    % ***** (2) ordinary Moore-Penrose of translational Jacobian *****
	geometryJacobian_inv = geometryJacobian' / (geometryJacobian * geometryJacobian');
	
    %% 3-b. figure out refence joint-space velocity/acceleration and sliding mode vector
    e = [dx - x; rotationErrorByEqAxis(eeEuler, dEuler)];
	rqdot = geometryJacobian_inv * ([dxdot;zeros(3,1)] + K_x1 * e);
	rxdotdot = [dxdotdot;zeros(3,1)] - D_x2 * (geometryJacobian*qdot-[dxdot;zeros(3,1)]) + K_x2 * e;
	rqdotdot = geometryJacobian_inv * (rxdotdot - geometryJacobian_dot*geometryJacobian_inv*[dxdot;zeros(3,1)]);
	s = qdot - rqdot;
	
	%% 3-b. formulate control law for sliding mode control, using sat function
	tau = M * rqdotdot + C + G - K_s * min(0.03, max(-0.03, s));

	% the tau(7) is set to 0. since its mass is too small for torque control. 
    % otherwise it will induce instability
	tau(7) = 0;

    %% 4. set the torque in vrep way
    for i = 1:jointNum
        if tau(i) < -forceLimit
            setForce = -forceLimit;
        elseif tau(i) > forceLimit
            setForce = +forceLimit;
        else
            setForce = tau(i); % set a trememdous large velocity for the screwy operation of the vrep torque control implementaion
        end
        vrep.simxSetJointTargetVelocity(clientID, jointHandle(i), sign(setForce)*1e10, vrep.simx_opmode_oneshot);% 决定了力的方向
        tau(i) = setForce;
        if setForce < 0
            setForce = -setForce;
        end
        vrep.simxSetJointForce(clientID, jointHandle(i),setForce , vrep.simx_opmode_oneshot);           
    end

	%% 5. data stream recording for plotting
	t = t + dt;     % updata simulation time
	T = [T t];
    X = [X; x']; DX = [DX; dx']; ERR = [ERR;[dx-x;convertToEuler(dEuler, eeEuler)]'];
    U = [U; tau']; Q = [Q; q']; QDOT = [QDOT; qdot'];
    disptime = sprintf('Simulation Time: %f s', t); 
	disp(disptime);

    %% 6. update vrep(the server side) matlab is client
	vrep.simxSynchronousTrigger(clientID);
    vrep.simxGetPingTime(clientID);     % MAKE SURE connection is still on
    lastCmdTime = currCmdTime;
end
vrep.simxFinish(-1);  % close the link
vrep.delete();        % destroy the 'vrep' class

%% PLOT FIGURES
figure(1); hold on;
plot(T, ERR(:, 1), 'r', 'LineWidth', 1.0);
plot(T, ERR(:, 2), 'g', 'LineWidth', 1.0);
plot(T, ERR(:, 3), 'b', 'LineWidth', 1.0);
legend('X-axis', 'Y-axis', 'Z-axis');
xlabel('Time Elapsed[s]');
ylabel('Cartesian Error[m]');
title({'End-effector Position Error'; 'of Trajectory Controller (SMC-sat)'});
savefig('results\6dof\trajsat_cartpos_error.fig');

figure(2);
plot3(DX(:, 1), DX(:, 2), DX(:, 3), 'r', 'LineWidth', 1.0); hold on;
plot3(X(:, 1), X(:, 2), X(:, 3), 'b', 'LineWidth', 1.0); 
legend('Real Traj', 'Desired Traj');
xlabel('X-axis[m]'); ylabel('Y-axis[m]'); zlabel('Z-axis[m]');
zlim([0.45, 0.55]);
title('End-effector Cartesian Path of Trajectory Controller (SMC-sat)'); grid on;
savefig('results\6dof\trajsat_cartpos_path.fig');

figure(3); hold on;
plot(T, ERR(:, 4), 'r', 'LineWidth', 1.0)
plot(T, ERR(:, 5), 'g', 'LineWidth', 1.0)
plot(T, ERR(:, 6), 'b', 'LineWidth', 1.0)
legend('X-axis', 'Y-axis', 'Z-axis');
xlabel('Time Elapsed[s]');
ylabel('Orientation Error[rad]');
title({'End-effector Orientation Error of'; 'Trajectory Controller (SMC-sat)'});
savefig('results\6dof\trajsat_cartrot_error.fig');

plotJointFigures(4, T, U, "Joint Torque of Trajectory Controller (SMC-sat)", 'Torque[Nm]')
savefig('results\6dof\trajsat_joint_torque.fig');
plotJointFigures(5, T, Q, "Joint Configuration of Trajectory Controller (SMC-sat)", 'Angle[rad]')
savefig('results\6dof\trajsat_joint_config.fig');
plotJointFigures(6, T, QDOT, "Joint Velocity of Trajectory Controller (SMC-sat)", 'Velocity[rad/s]')
savefig('results\6dof\trajsat_joint_vel.fig');

rmpath('..\..\libs')